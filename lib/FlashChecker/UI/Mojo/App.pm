package FlashChecker::UI::Mojo::App;
use strict;
use warnings FATAL => 'all';

use Mojolicious::Lite;
use Cwd qw(abs_path);
use File::Basename qw(dirname);

use Mojo::IOLoop;
use Data::Dumper;

use FlashChecker::UI::Mojo::EventsHandler;

my $handler = FlashChecker::UI::Mojo::EventsHandler->new();

sub run {
    my ( $queue ) = @_;

    init();

    $handler->start($queue);

    return app->start(
        'daemon', 'morbo', '-l' => 'http://*:8080',
        'home'         => dirname(abs_path($0))
    );
}

sub init {
    push(@{app->renderer->paths}, ( dirname(abs_path($0)) . "/templates" ));
    define_routes();

    return 1;
}



sub define_routes {
    websocket '/ws' => sub {my $self = shift; $handler->new_client($self)};

    get '/' => sub {
        my $c = shift;
        $c->render(template => 'index');
    };
}


1;