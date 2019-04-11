package USB::_Execute;
use strict;
use warnings FATAL => 'all';

use Carp;

use Exporter 'import';
our @EXPORT = ('execute');

sub execute {
    my ( $cmd, $description ) = @_;
    my $output;
    eval {
        `chcp 65001 > NUL`;
        $output = `$cmd`;
    } or do {
        confess
          "Failed to execute '$description' command.\n\nCMD: '$cmd'\n\n $@";
    };

    Encode::from_to($output, 'cp866', 'utf8' );
    return [ split( /[\r\n]/, $output ) ];
}

1;
