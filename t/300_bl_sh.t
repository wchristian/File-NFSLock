# Blocking Shared Lock Test

use Test;
use File::NFSLock;
use Fcntl qw(O_CREAT O_RDWR O_RDONLY O_TRUNC O_APPEND LOCK_EX LOCK_NB LOCK_SH);

# $m simultaneous processes trying to obtain a shared lock
my $m = 20;

$| = 1; # Buffer must be autoflushed because of fork() below.
plan tests => ($m*2 + 11);

my $datafile = "testfile.dat";

# Create a blank file
sysopen ( FH, $datafile, O_CREAT | O_RDWR | O_TRUNC );
close (FH);
ok (-e $datafile && !-s _);


ok (pipe(RD1,WR1)); # Connected pipe for child1
if (!fork) {
  # Child #1 process
  # Obtain exclusive lock to block the shared attempt later
  my $lock = new File::NFSLock {
    file => $datafile,
    lock_type => LOCK_EX,
  };
  print WR1 !!$lock; # Send boolean success status down pipe
  close(WR1); # Signal to parent that the Blocking lock is done
  close(RD1);
  if ($lock) {
    sleep 2;  # hold the lock for a moment
    sysopen(FH, $datafile, O_RDWR | O_TRUNC);
    # And then put a magic word into the file
    print FH "exclusive\n";
    close FH;
  }
  exit;
}
ok 1; # Fork successful
close (WR1);
# Waiting for child1 to finish its lock status
my $child1_lock = <RD1>;
close (RD1);
# Report status of the child1_lock.
# It should have been successful
ok ($child1_lock);


ok (pipe(RD2,WR2)); # Connected pipe for child2
if (!fork) {
  # This should block until the exclusive lock is done
  my $lock = new File::NFSLock {
    file => $datafile,
    lock_type => LOCK_SH,
  };
  if ($lock) {
    sysopen(FH, $datafile, O_RDWR | O_TRUNC);
    # Immediately put the magic word into the file
    print FH "shared\n";
    truncate (FH, tell FH);
    close FH;
    # Normally shared locks never modify the contents because
    # of the race condition.  (The last one to write wins.)
    # But in this case, the parent will wait until the lock
    # status is reported (close RD2) so it defines execution
    # sequence will be correct.  Hopefully the shared lock
    # will not happen until the exclusive lock has been released.
    # This is also a good test to make sure that other shared
    # locks can still be obtained simultaneously.
  }
  print WR2 !!$lock; # Send boolean success status down pipe
  close(WR2); # Signal to parent that the Blocking lock is done
  close(RD2);
  # Then hold the shared lock for a moment
  # while other shared locks are attempted
  sleep 5;
  exit; # Release the shared lock
}
ok 1; # Fork successful
close (WR2);
# Waiting for child2 to finish its lock status
my $child2_lock = <RD2>;
close (RD2);
# Report status of the child2_lock.
# This should have eventually been successful.
ok ($child2_lock);

# If all these processes take longer than 2 seconds,
# then they are probably not running synronously
# and the shared lock is not working correctly.
# But if all the children obatin the lock simultaneously,
# like they are supposed to, then it shouldn't take
# much longer than the maximum delay of any of the
# shared locks (at least 5 seconds set above).
$SIG{ALRM} = sub {
  ok 0;
  die "Shared locks not running simultaneously";
};
alarm(10);

for (my $i = 0; $i < $m ; $i++) {
  if (!fork) {
    # All of these locks should immediately be successful since
    # there already exist a shared lock.
    my $lock = new File::NFSLock {
      file => $datafile,
      lock_type => LOCK_SH,
    };
    if ($lock) {
      sleep 2;  # Hold the shared lock for a moment
      # Appending is always safe across NFS
      sysopen(FH, $datafile, O_RDWR | O_APPEND);
      # Put one line to signal the lock was successful.
      print FH "1\n";
      close FH;
    }
    exit;
  }
}


# There are $m children plus the first exclusive locker child
# and the second child obtaining the first shared lock.
for (my $i = 0; $i < $m + 2 ; $i++) {
  # Wait until all the children are finished.
  wait;
  ok 1;
}

# If we made it here, then it must have been faster
# than the timeout.  So reset the timer.
alarm(0);
ok 1;

# Load up whatever the file says now
sysopen(FH, $datafile, O_RDONLY);

# The first line should say "shared" if child2 really
# waited for child1's exclusive lock to finish.
$_ = <FH>;
ok /shared/;

for (my $i = 0; $i < $m ; $i++) {
  $_ = <FH>;
  chomp;
  ok $_, 1;
}
close FH;

# Wipe the temporary file
unlink $datafile;