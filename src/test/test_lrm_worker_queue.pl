#!/usr/bin/perl

use v5.36;

use lib qw(..);

use Test::More;

use PVE::HA::LRM;

# minimal environment stub, it provides only what the LRM needs to handle its
# worker queue, the time is faked to not wait for real in the worker loop
package TestEnv;

sub new {
    my ($class, $max_workers) = @_;

    my $self = bless {
        max_workers => $max_workers,
        time => 0,
    }, $class;

    return $self;
}

# every call advances the fake clock, so the worker loop runs only one iteration
sub get_time {
    my ($self) = @_;

    $self->{time} += 5;

    return $self->{time};
}

sub get_max_workers {
    my ($self) = @_;

    return $self->{max_workers};
}

sub read_service_config {
    return {};
}

sub log {
    return;
}

sub sleep {
    return;
}

sub after_fork {
    return;
}

sub nodename {
    return 'node1';
}

package TestLRM;

use base qw(PVE::HA::LRM);

# do not run any real resource agent, just pretend the command succeeded
sub exec_resource_agent {
    my ($self, $sid, $service_config, $cmd, $params) = @_;

    return 0;
}

package main;

# the LRM can only run a single worker at a time, so with more resources than
# workers some of them have to wait for a free slot
my $env = TestEnv->new(1);
my $lrm = TestLRM->new($env);
$lrm->{service_status} = {};

my @sids = ('vm:100', 'vm:800', 'vm:900');

# get a worker entry without autovivifying it
sub worker {
    my ($sid) = @_;

    return $lrm->{workers}->{$sid};
}

# the CRM renews the request uid of every service in each round, so the LRM
# queues the already pending workers again
sub queue_all {
    my ($uid_prefix) = @_;

    my $uid = 0;
    for my $sid (@sids) {
        $uid++;
        $lrm->queue_resource_command($sid, "$uid_prefix-$uid", 'started');
    }
}

# first round, only the first worker fits into the single slot, the others have
# to wait for a free slot
queue_all('uid');

$lrm->run_workers();

ok(worker('vm:100')->{pid}, 'first worker got the only slot');
ok(!worker('vm:800')->{pid}, 'second worker is still pending');
ok(!worker('vm:900')->{pid}, 'third worker is still pending');

my $tries = worker('vm:800')->{start_tries};
is($tries, 1, 'pending worker counted its try');

$tries = worker('vm:900')->{start_tries};
is($tries, 1, 'pending worker counted its try');

# second round, the workers are queued again with a renewed request uid
queue_all('uid2');

$tries = worker('vm:800')->{start_tries};
is($tries, 1, 'pending worker keeps its try counter when queued again');

$tries = worker('vm:900')->{start_tries};
is($tries, 1, 'pending worker keeps its try counter when queued again');

# wait for the first worker to finish, so its slot gets freed in the next round
sleep 1;
$lrm->run_workers();

ok(!worker('vm:100'), 'first worker finished');
ok(worker('vm:800')->{pid}, 'second worker got the freed slot');

# third round, the workers are queued again with a renewed request uid, while
# the first worker is queued freshly as it already finished before
queue_all('uid3');

sleep 1;
$lrm->run_workers();

# the third worker waited the longest, so it has to be preferred over the
# freshly queued first worker, else the first worker wins over and over again
ok(worker('vm:900')->{pid}, 'worker which waited longest got the freed slot');
ok(!worker('vm:100')->{pid}, 'freshly queued worker did not get the slot');

# reap the remaining worker
sleep 1;
$lrm->check_active_workers();

done_testing();
