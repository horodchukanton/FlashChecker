package USB::Listener;
use strict;
use warnings FATAL => 'all';

use threads;
use threads::shared qw/share/;
use Thread::Queue;

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

    $self->{os} = ( $^O =~ 'MSWin32' ) ? 'win' : 'lin';

    return $self;
}

sub listen {
    my ( $self, %params ) = @_;
    my $period = $params{period} || 5;

    # Get initial list
    $self->{devices} = $self->get_list_of_devices() unless @{$self->{devices}};
    $self->{events_queue} = Thread::Queue->new({ type => 'start' });

    # Start a thread
    $self->{listener} = threads::async sub {listener_thread($self, $period)};
    $self->{listener}->detach();

    return 1;
}

sub listener_thread {
    my ( $self, $period ) = @_;

    while (1) {
        $self->check_for_changed_devices();
        sleep $period;
    }
}

sub check_for_changed_devices {
    my ($self) = @_;

    my $queue = $self->{events_queue};
    my @old_ids = map {$_->identifier()} @{$self->{devices}};

    my $new_list = $self->get_list_of_devices();
    my @new_ids = map {$_->identifier()} @{$new_list};

    my ( $changed, $created, $removed ) = _compare_lists(\@old_ids, \@new_ids);

    if ($changed) {
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
        push @removed, $o if !grep { $o eq $_} @$new;
    }

    # Checking created
    my @created = ();
    for my $n (@$new) {
        push @created, $n if !grep { $n eq $_} @$old;
    }

    return 0 if (! @created && ! @removed);
    return( 1, \@created, \@removed );
}

sub get_list_of_devices {
    my ( $self ) = @_;

    my $list = ( $self->{os} eq 'win' )
        ? $self->get_devices_win()
        : $self->get_devices_lin();

    return $list;
}

sub get_devices_win {
    my $self = shift;
    my $cmd = 'wmic logicaldisk where drivetype=2 get deviceid,volumeserialnumber /FORMAT:list';
    my $list = $self->_execute_cmd($cmd, "List of the devices");

    # Windows returns the list starting with 'DeviceID=G:'
    my @result = ();

    my %current_device_opts = ();
    for (@$list) {
        next unless $_;

        my ( $name, $value ) = split('=', $_, 2);

        # Next device started
        if (%current_device_opts && $name eq 'DeviceID') {
            $current_device_opts{DeviceID} = $value;
            push @result, USB::Device->new(%current_device_opts) if ($current_device_opts{VolumeSerialNumber});
            %current_device_opts = ();
            next;
        }

        $current_device_opts{$name} = $value;
    }

    # Saving last one (if any keys are present)
    if (%current_device_opts) {
        push @result, USB::Device->new(%current_device_opts) if ($current_device_opts{VolumeSerialNumber});
    }

    return \@result;
}

sub get_info_win {

}

sub get_devices_lin {
    my $self = shift;
    my $cmd = q{ls -1 /dev/disk/by-id/ | grep -v -E '\-part[0-9]+$' | grep '^usb'};
    return $self->_execute_cmd($cmd, "List of the devices");

}

sub get_info_lin {

}

sub _execute_cmd {
    my ( $self, $cmd, $description ) = @_;
    my $output;
    eval {
        $output = `$cmd`;
    } or do {
        confess "Failed to execute '$description' command.\nOS:'$self->{os}'\nCMD: '$cmd'\n";
    };

    return [ split(/[\r\n]+/, $output) ];
}

1;