package FlashChecker;
use strict;
use warnings FATAL => 'all';

use Carp;
use Data::Dumper;
use USB::Listener;
use FlashChecker::UI;

sub new {
    my ( $class, $config ) = shift;
    my $self = { config => $config };
    bless $self, $class;

    $self->{listener} = USB::Listener->new(debug => 1);

    my $ui_type = $self->{config}->{UI}->{Type};
    $self->{ui} = FlashChecker::UI->new(ui => $ui_type, do_not_start => 1);

    return $self;
}

sub start {
    my ( $self ) = @_;

    my $events_queue = $self->{listener}->listen();

    return $self->{ui}->start(
        config => $self->{config},
        queue  => $events_queue
    );
}





1;