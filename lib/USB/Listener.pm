package USB::Listener;
use strict;
use warnings FATAL => 'all';

use threads;
use threads::shared qw/share/;
use Thread::Queue;

use Data::Dumper;
use Carp;

use USB::Devices;

my @devices;
my %devices_by_id;
my Thread::Queue $events_queue :shared;

# Listener thread
my threads $listener;

sub new {
    my ( $class, %params ) = @_;
    my $self = {
        system => USB::Devices->new(),
        %params
    };
    bless $self, $class;
    return $self;
}

#@returns Thread::Queue
sub listen {
    my ( $self, %params ) = @_;
    my $period = $params{period} || 5;

    # Get initial list
    $self->update_list_of_devices(
        $self->system->get_list_of_devices()
    );

    # Start a thread
    print "Starting a USB::Listener thread\n" if ($self->{debug});

    $events_queue = Thread::Queue->new({ type => 'start' });
    $listener = threads::async sub {listener_thread($self, $period)};

    return $events_queue;
}

sub stop {
    print "Stopping USB::Listener thread\n";
    $listener->kill();
    $listener->detach();

}

sub listener_thread {
    my ( $self, $period ) = @_;

    while (1) {
        $self->check_for_changed_devices();
        sleep $period;
    }
}

sub check_for_changed_devices {
    my ( $self ) = @_;

    my @old_ids = map {$_->{id}} @devices;

    my $new_list = $self->system->get_list_of_devices();
    my @new_ids = map {$_->{id}} @{$new_list};

    my ( $changed, $created, $removed ) = _compare_lists(\@old_ids, \@new_ids);

    if ($changed) {
        if ($self->{debug}) {
            print "Device connected: $_.  \n" for @$created;
            print "Device disconnected: $_.  \n" for @$removed;
        }

        if (@$created) {
            # Map by id
            my %new_device_ids = map {$_ => 1} @$created;
            for (@$new_list) {
                next unless ($new_device_ids{$_->{id}});
                $events_queue->enqueue({
                    type   => 'connected',
                    id     => $_->{id},
                    device => $_
                });
            }
        }
        if (@$removed) {
            $events_queue->enqueue({
                type => 'removed', id => $_
            }) for @$removed;
        }
    }

    $self->update_list_of_devices($new_list);
}

sub _compare_lists {
    my ( $old, $new ) = @_;

    # Checking old contains all of new
    my @removed = ();
    for my $o (@$old) {
        push @removed, $o if ! grep {$o eq $_} @$new;
    }

    # Checking created
    my @created = ();
    for my $n (@$new) {
        push @created, $n if ! grep {$n eq $_} @$old;
    }

    return 0 if (! @created && ! @removed);
    return( 1, \@created, \@removed );
}


sub get_list_of_devices {
    return [ @devices ];
}

sub get_device_info {
    my ( undef, $device_id ) = @_;
    return $devices_by_id{$device_id};
}

sub update_list_of_devices {
    my ( $self, $new_devices ) = @_;
    for (@$new_devices){
        $devices_by_id{$_->{id}} = $_;
    }
    @devices = @$new_devices;
}

#@returns USB::Devices
sub system {
    return shift->{system};
}

DESTROY{
    $listener->detach();
}

1;