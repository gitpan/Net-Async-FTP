#!/usr/bin/perl -w

use strict;

use Test::More tests => 5;
use IO::Async::Test;
use IO::Async::Loop;
use IO::Async::Stream;

use Net::Async::FTP;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop->new();
testing_loop( $loop );

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

my $ftp = Net::Async::FTP->new(
   handle => $S1,
);

$loop->add( $ftp );

# We won't log in.. our pseudo-server will just accept any command

my $done;

$ftp->dele(
   path => "path/to/file",
   on_done => sub { $done = 1 },
);

my $server_stream = "";
wait_for_stream { $server_stream =~ m/$CRLF/ } $S2 => $server_stream;

is( $server_stream, "DELE path/to/file$CRLF", 'DELE command' );

$S2->syswrite( "250 Completed$CRLF" );

wait_for { $done };

is( $done, 1, '$done after 250' );

$done = 0;

$ftp->rename(
   oldpath => "some/oldname",
   newpath => "some/newname",
   on_done => sub { $done = 1 },
);

$server_stream = "";
wait_for_stream { $server_stream =~ m/$CRLF/ } $S2 => $server_stream;

is( $server_stream, "RNFR some/oldname$CRLF", 'RNFR command' );

$S2->syswrite( "350 More information required$CRLF" );

$server_stream = "";
wait_for_stream { $server_stream =~ m/$CRLF/ } $S2 => $server_stream;

is( $server_stream, "RNTO some/newname$CRLF", 'RNTO command' );

$S2->syswrite( "250 Completed$CRLF" );

wait_for { $done };

is( $done, 1, '$done after 250' );
