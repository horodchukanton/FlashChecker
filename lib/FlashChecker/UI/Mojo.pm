package FlashChecker::UI::Mojo;
use strict;
use warnings FATAL => 'all';

use FlashChecker::UI::Mojo::App;

sub new {
    my ($class, %params) = @_;
    my $self = { %params };
    bless $self, $class;
    return $self;
}

sub run {
    my ($self, $params) = @_;
    my $queue = $params->{queue};

    FlashChecker::UI::Mojo::App::run($queue);
}

1;