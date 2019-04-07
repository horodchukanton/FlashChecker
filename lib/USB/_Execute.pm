package USB::_Execute;
use strict;
use warnings FATAL => 'all';

use Carp;

use Exporter 'import';

our @EXPORT = (
    'execute'
);

sub execute {
    my ( $cmd, $description ) = @_;
    my $output;
    eval {
        $output = `$cmd`;
    } or do {
        confess "Failed to execute '$description' command.\n\nCMD: '$cmd'\n";
    };

    return [ split(/[\r\n]+/, $output) ];
}

1;