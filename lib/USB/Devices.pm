package USB::Devices;
use strict;
use warnings FATAL => 'all';

my $WIN_ATTRS = 'filesystem,size,volumeserialnumber,deviceid,filesystem,description';
use USB::_Execute qw/execute/;

sub new {
    my ($class, %params) = @_;
    my $self = { %params };
    bless $self, $class;

    $self->{os} ||= ( $^O =~ 'MSWin32' ) ? 'win' : 'lin';

    return $self;
}

sub get_list_of_devices {
    my ( $self ) = @_;

    my $list = ( $self->{os} eq 'win' )
        ? get_devices_win()
        : get_devices_lin();

    return $list;
}

sub get_device_info {
    my ( $self, $device_id ) = @_;

    my $info = ( $self->{os} eq 'win' )
        ? get_info_win($device_id)
        : get_info_lin($device_id);

    return $info->[0];
}

sub get_devices_win {
    my $cmd = 'wmic logicaldisk where drivetype=2 '
        . "get ${WIN_ATTRS} /FORMAT:list";
    my $cmd_result = execute($cmd, "List of the devices");
    return [] unless (scalar @$cmd_result);

    my $list = _parse_win_keypairs($cmd_result);

    return [ map {$_->{id} = $_->{DeviceID};
        $_} @$list ]
}

sub get_info_win {
    my ( $device_id ) = @_;

    my $cmd = qq{wmic logicaldisk where "drivetype=2 and deviceid=\"$device_id\"" }
        . qq{get ${WIN_ATTRS} /FORMAT:list};

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


    # Remove empty lines
    while ($cmd_output->[0] eq '') {
        shift(@$cmd_output)
    }

    # Result should go in the same order, get name of the first pair
    my $first_name = ( split('=', $cmd_output->[0], 2) )[0];

    my @result = ();

    my %current_device_opts = ();
    for (@$cmd_output) {
        next unless $_;
        my ( $name, $value ) = split('=', $_, 2);

        # Next device started
        if ($name eq $first_name && %current_device_opts) {
            push @result, { %current_device_opts };
            %current_device_opts = ( $first_name => $value );
            next;
        }

        $current_device_opts{$name} = $value;
    }

    # Saving last one (if any keys are present)
    if ($current_device_opts{$first_name}) {
        push @result, \%current_device_opts;
    }

    # Description can contain UTF-8 characters
    for (@result){
        $_->{Description} = Encode::decode_utf8($_->{Description})
            if ($_->{Description});
    }

    return \@result;
}


1;