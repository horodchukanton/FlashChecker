package USB::Listener;
use strict;
use warnings FATAL => 'all';

use threads;
use threads::shared qw/share/;
use Thread::Queue;

use USB::_Execute qw/execute/;

use Data::Dumper;
use Carp;

sub new {
    my ( $class, %params ) = @_;
    my $self = {
        devices      => [],
        events_queue => undef,
        %params
    };
    bless $self, $class;

    $self->{os} ||= ( $^O =~ 'MSWin32' ) ? 'win' : 'lin';

    return $self;
}

sub listen {
    my ( $self, %params ) = @_;
    my $period = $params{period} || 5;

    # Get initial list
    $self->{devices} = $self->get_list_of_devices() unless @{$self->{devices}};
    $self->{events_queue} = Thread::Queue->new({ type => 'start' });

    # Start a thread
    print "Starting a USB::Listener thread\n" if ($self->{debug});
    $self->{listener} = threads::async sub {listener_thread($self, $period)};
    # $self->{listener}->detach();

    return $self->{events_queue};
}

sub stop {
    my ( $self ) = @_;
    print "Stopping USB::Listener thread\n";
    $self->{listener}->kill();
    $self->{listener}->detach();

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

    my $queue = $self->{events_queue};
    my @old_ids = map {$_->{id}} @{$self->{devices}};

    my $new_list = $self->get_list_of_devices();
    my @new_ids = map {$_->{id}} @{$new_list};

    my ( $changed, $created, $removed ) = _compare_lists(\@old_ids, \@new_ids);

    if ($changed) {
        if ($self->{debug}) {
            print "Device connected: $_.  \n" for @$created;
            print "Device disconnected: $_.  \n" for @$removed;
        }

        $queue->enqueue({ type => 'connected', id => $_ }) for @$created;
        $queue->enqueue({ type => 'removed', id => $_ }) for @$removed;
    }

    $self->{devices} = $new_list;
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
    my ( $self ) = @_;

    my $list = ( $self->{os} eq 'win' )
        ? get_devices_win()
        : get_devices_lin();

    return $list;
}

sub get_device_info {
    my ( $self ) = @_;

    my $info = ( $self->{os} eq 'win' )
        ? get_info_win()
        : get_info_lin();

    return $info;
}

sub get_devices_win {
    my $cmd = 'wmic logicaldisk where drivetype=2 get deviceid,volumeserialnumber /FORMAT:list';
    my $cmd_result = execute($cmd, "List of the devices");

    my $list = _parse_win_keypairs($cmd_result);
    return [ map {$_->{id} = $_->{VolumeSerialNumber}; $_} @$list ]
}

sub get_info_win {
    my ( $device_id ) = @_;

    my $cmd = qq{wmic logicaldisk where "drivetype=2 and volumeserialnumber=\"$device_id\""}
     . q{get filesystem,size,volumeserialnumber,deviceid,filesystem,description /FORMAT:list};

    my $list = execute($cmd, "Device info");

    return _parse_win_keypairs($list);
}


sub get_devices_lin {
    my $cmd = q{ls -1 /dev/disk/by-id/ | grep -v -E '\-part[0-9]+$' | grep '^usb'};
    return execute($cmd, "List of the devices");

}

sub get_info_lin {
  die "get_info_lin Unimplemented";
}

sub _parse_win_keypairs {
    my ( $cmd_output ) = @_;

    my @result = ();
    # Windows returns the list starting with 'DeviceID=G:'

    my %current_device_opts = ();
    for (@$cmd_output) {
        next unless $_;

        my ( $name, $value ) = split('=', $_, 2);

        # Next device started
        if (%current_device_opts && $name eq 'DeviceID') {
            $current_device_opts{DeviceID} = $value;
            push @result, \%current_device_opts;
            %current_device_opts = ();
            next;
        }

        $current_device_opts{$name} = $value;
    }

    # Saving last one (if any keys are present)
    if (%current_device_opts) {
        push @result, \%current_device_opts;
    }

    return \@result;
}

DESTROY{
    my $self = shift;
    $self->{listener}->detach();
}

1;