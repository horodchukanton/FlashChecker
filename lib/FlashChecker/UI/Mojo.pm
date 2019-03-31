package FlashChecker::UI::Mojo;
use strict;
use warnings FATAL => 'all';

use Mojolicious::Lite;
use Cwd            qw( abs_path );
use File::Basename qw( dirname );

sub import () {

    websocket '/echo' => sub {
        my $c = shift;
        $c->on(json => sub {
            my ($c, $hash) = @_;
            $hash->{msg} = "echo: $hash->{msg}";
            $c->send({json => $hash});
        });
    };

    get '/' => sub {
        my $c = shift;
        $c->render(template => 'index');
    };

    push (@{app->renderer->paths}, (dirname(abs_path($0)) . "/templates"));

    return app->start(
        'daemon', '-l' => 'http://*:8080',
        'home'         => dirname(abs_path($0))
    );
}

1;