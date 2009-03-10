#!/usr/bin/perl -w

use strict;

use Test::More tests => 16;
use IO::Async::Test;
use IO::Async::Loop;
use IO::Async::Stream;

use Net::Async::FTP;
use t::TestFTP;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop->new();
testing_loop( $loop );

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

my $ftp = Net::Async::FTP->new(
   handle => $S1,
);

$loop->add( $ftp );

# We won't log in.. our pseudo-server will just accept any command

my $list_response = "drwxr-xr-x   2 user     user            0 Feb  1  2005 .$CRLF" .
                    "-rw-r--r--   1 user     user          100 Feb  2  2005 file$CRLF" .
                    "-rw-r--r--   1 user     user          200 Feb  3  2005 other$CRLF";

my $done;
my $list;

$ftp->list(
   path => "some/dir",
   on_list => sub { $list = shift; $done = 1; },
);

my $server_stream = "";
wait_for_stream { $server_stream =~ m/$CRLF/ } $S2 => $server_stream;

is( $server_stream, "PASV$CRLF", 'PASV preceeds LIST' );

my $D = accept_dataconn( $S2 );

$server_stream = "";
wait_for_stream { $server_stream =~ m/$CRLF/ } $S2 => $server_stream;

is( $server_stream, "LIST some/dir$CRLF", 'LIST command' );

$D->syswrite( $list_response );
$D->close;

$S2->syswrite( "226 Closing data connection$CRLF" );

wait_for { $done };

is( $done, 1, '$done after 226' );
is( $list, "drwxr-xr-x   2 user     user            0 Feb  1  2005 .$CRLF" .
           "-rw-r--r--   1 user     user          100 Feb  2  2005 file$CRLF" .
           "-rw-r--r--   1 user     user          200 Feb  3  2005 other$CRLF",
    '$list after 226' );

my @files;
$done = 0;

$ftp->list_parsed(
   path => "some/dir",
   on_list => sub { @files = @_; $done = 1; },
);

$server_stream = "";
wait_for_stream { $server_stream =~ m/$CRLF/ } $S2 => $server_stream;

is( $server_stream, "PASV$CRLF", 'PASV preceeds LIST' );

$D = accept_dataconn( $S2 );

$server_stream = "";
wait_for_stream { $server_stream =~ m/$CRLF/ } $S2 => $server_stream;

is( $server_stream, "LIST some/dir$CRLF", 'LIST command' );

$D->syswrite( $list_response );
$D->close;

$S2->syswrite( "226 Closing data connection$CRLF" );

wait_for { $done };

is( $done, 1, '$done after 226' );
is_deeply( \@files,
           [
              { name => "file",  type => "f", size => 100, mtime => 1107302400, mode => 0100644 },
              { name => "other", type => "f", size => 200, mtime => 1107388800, mode => 0100644 },
           ],
           '@files after 226' );

$done = 0;
my $names;

$ftp->nlst(
   path => "other/dir",
   on_list => sub { $names = shift; $done = 1; },
);

$server_stream = "";
wait_for_stream { $server_stream =~ m/$CRLF/ } $S2 => $server_stream;

is( $server_stream, "PASV$CRLF", 'PASV preceeds NLST' );

$D = accept_dataconn( $S2 );

$server_stream = "";
wait_for_stream { $server_stream =~ m/$CRLF/ } $S2 => $server_stream;

is( $server_stream, "NLST other/dir$CRLF", 'NLST command' );

$D->syswrite( "foo${CRLF}bar${CRLF}splot${CRLF}" );
$D->close;

$S2->syswrite( "226 Closing data connection$CRLF" );

wait_for { $done };

is( $done, 1, '$done after 226' );
is( $names, "foo${CRLF}bar${CRLF}splot${CRLF}", '$names after 226' );

$done = 0;
my @names;

$ftp->namelist(
   path => "other/dir",
   on_names => sub { @names = @_; $done = 1; },
);

$server_stream = "";
wait_for_stream { $server_stream =~ m/$CRLF/ } $S2 => $server_stream;

is( $server_stream, "PASV$CRLF", 'PASV preceeds NLST' );

$D = accept_dataconn( $S2 );

$server_stream = "";
wait_for_stream { $server_stream =~ m/$CRLF/ } $S2 => $server_stream;

is( $server_stream, "NLST other/dir$CRLF", 'NLST command' );

$D->syswrite( "foo${CRLF}bar${CRLF}splot${CRLF}" );
$D->close;

$S2->syswrite( "226 Closing data connection$CRLF" );

wait_for { $done };

is( $done, 1, '$done after 226' );
is_deeply( \@names,
           [qw( foo bar splot )],
           '@names after 226' );
