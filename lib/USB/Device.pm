package USB::Device;
use strict;
use warnings FATAL => 'all';

sub new {
    my ( $class, %params ) = @_;
    my $self = {
        %params
    };

    die "Need VolumeSerialNumber to be present.\n" unless $self->{VolumeSerialNumber};

    $self->{os} = ( $^O =~ 'MSWin32' ) ? 'win' : 'lin';

    bless $self, $class;
    return $self;
}

sub identifier {
    my ($self) = shift;
    return $self->{VolumeSerialNumber};
}

sub get_info {
    my ($self) = @_;

    my $cmd = '';
    if ($self->{os} eq 'win') {
        die "not implemented";

    }
    else {
        $cmd = '';
    }

    return $self->_execute($cmd)
}

sub _execute {
    my ($self, $cmd, $description) = @_;


}

1;