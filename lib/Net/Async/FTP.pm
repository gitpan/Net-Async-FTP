#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008 -- leonerd@leonerd.org.uk

package Net::Async::FTP;

use strict;
use warnings;
use base qw( IO::Async::Stream );

use Carp;

our $VERSION = '0.03';

use Socket qw( AF_INET SOCK_STREAM inet_aton pack_sockaddr_in );

my $CRLF = "\x0d\x0a";

=head1 NAME

C<Net::Async::FTP> - Asynchronous FTP client

=head1 SYNOPSIS

 use IO::Async::Loop;
 use Net::Async::FTP;

 my $loop = IO::Async::Loop->new();

 my $ftp = Net::Async::FTP->new();
 $loop->add( $ftp );

 $ftp->connect(
    host => "ftp.example.com",

    on_connected => sub {
       $ftp->login(
          user => "username",
          pass => "password",

          on_login => sub {
             $ftp->retr(
                path => "README.txt",

                on_data => sub {
                   my ( $data ) = @_;
                   print "README.txt says:\n";
                   print $data;
                   $loop->loop_stop;
                },
             );
          },
          on_error => sub { die shift() },
       );
    },
    on_error => sub { die shift() },
 );

 $loop->loop_forever;

=head1 DESCRIPTION

This object class implements an asynchronous FTP client, for use in
L<IO::Async>-based programs.

The code in this module is not particularly complete. It contains a minimal
implementation of a few FTP commands, not even the full minimal set the RFC
suggests all clients should support. I am releasing it anyway, because it is
still useful as it stands, and could easily support extra commands being added
if anyone would find it useful.

The (undocumented) C<do_command()> method provides a generic base for the
currently-implemented commands, and would be the basis for new commands.

As they say so often in the open-source world; Patches Welcome.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $ftp = Net::Async::FTP->new( %args )

This function returns a new instance of a C<Net::Async::FTP> object. As it is
a subclass of C<IO::Async::Stream> its constructor takes any arguments for
that class.

=cut

sub new
{
   my $class = shift;
   my %args = @_;

   my $self = $class->SUPER::new( %args );

   $self->{req_queue} = [];

   return $self;
}

sub on_read
{
   my $self = shift;
   my ( $buffref, $closed ) = @_;

   $self->_do_req_queue;

   if( my $item = shift @{ $self->{req_queue} } ) {
      return $item->{on_read};
   }

   return 0 unless $$buffref =~ s/^(.*)$CRLF//;
   print STDERR "Unexpected incoming line $1\n";
   return 1;
}

=head1 METHODS

=cut

=head2 $ftp->connect( %args )

Connects to the FTP server. Takes the following arguments:

=over 8

=item host => STRING

Hostname of the server

=item service => STRING or INT

Optional. Service name or port number to connect to. If not supplied, will use
C<ftp>.

=item family => INT

Optional. Socket family to use. Will default to whatever C<getaddrinfo()>
returns if not supplied.

=item on_connected => CODE

Continuation to call when connection is successful

 $on_connected->()

=item on_error => CODE

Continuation to call on an error

 $on_error->( $message )

=back

=cut

sub connect
{
   my $self = shift;
   my %args = @_;

   my $loop = $self->get_loop or croak "Cannot ->connect a ".ref($self)." that is not in a Loop";

   my $on_connected = $args{on_connected};
   ref $on_connected eq "CODE" or croak "Expected 'on_connected' as a CODE reference";

   my $on_error = $args{on_error};
   ref $on_error eq "CODE" or croak "Expected 'on_error' as a CODE reference";

   $loop->connect(
      host     => $args{host},
      service  => $args{service} || "ftp",
      socktype => SOCK_STREAM,
      family   => $args{family},

      on_connected => sub {
         my ( $sock ) = @_;

         $self->set_handle( $sock );

         # TODO: This is a bit messy. Install an initial on_read handler for
         # the connect messages, by sending an "empty string" command
         $self->do_command( undef,
            220 => $on_connected,
         );
      },

      on_resolve_error => $on_error,
      on_connect_error => sub { $on_error->( "Cannot connect" ) },
   );
}

my %NUMTYPES = (
   1 => "info",
   2 => "ok",
   3 => "more",
   4 => "err",
   5 => "err",
);

sub _build_codemap_onread
{
   my $self = shift;
   my ( $command, $codemap ) = @_;

   my @extralines;

   sub {
      my ( $self, $buffref, $closed ) = @_;

      return 0 unless $$buffref =~ s/^(.*)$CRLF//;
      my $line = $1;

      if( $line =~ m/^(\d\d\d) +(.*)$/ ) {
         my ( $number, $message ) = ( $1, $2 );
         my $numtype = $NUMTYPES{substr($number, 0, 1)};

         my $cb = $codemap->{$number} || $codemap->{$numtype};

         if( $cb ) {
            my $ret = $cb->( $number, $message, @extralines );
            undef @extralines;

            # If it's a 1xx command, we're not finished yet
            return 1 if $numtype eq "info";

            return $ret if ref $ret eq "CODE";
            return undef;
         }
         elsif( $numtype ne "info" ) {
            print STDERR "Unexpected incoming num $number message $message while awaiting response to $command\n";
            print STDERR "  $_\n" for @extralines;
         }
      }
      elsif( $line =~ m/^(\d\d\d)-(.*)$/ ) {
         push @extralines, $2;
      }
      else {
         print STDERR "Unparsable incoming line $line\n";
      }

      return 1;
   };
}

sub do_command
{
   my $self = shift;
   my ( $command, %codemap ) = @_;

   my $on_read = $self->_build_codemap_onread( $command, \%codemap );

   my $queue = $self->{req_queue};
   push @$queue, { command => $command, on_read => $on_read };

   $self->_do_req_queue;
}

sub _do_req_queue
{
   my $self = shift;

   my $queue = $self->{req_queue};
   return unless @$queue;

   my $item = $queue->[0];

   if( defined $item->{command} ) {
      $self->write( "$item->{command}$CRLF" );
      undef $item->{command};
   }
}

sub _connect_dataconn
{
   my $self = shift;
   my ( $on_conn, $on_error, $command, $on_conn_codemap ) = @_;

   $self->pasv(
      on_done => sub {
         my ( $ip, $port ) = @_;

         my $sinaddr = pack_sockaddr_in( $port, inet_aton( $ip ) );

         my $loop = $self->get_loop;
         $loop->connect(
            addr => [ AF_INET, SOCK_STREAM, 0, $sinaddr ],

            on_connected => $on_conn,
            on_connect_error => sub { $on_error->( "Cannot connect" ) },
         );

         $self->write( "$command$CRLF" );

         return $self->_build_codemap_onread( $command, $on_conn_codemap );
      },

      on_error => $on_error,
   );
}

# Now some convenient wrappers for classes of command

sub _do_command_collect_dataconn
{
   my $self = shift;
   my ( $command, $on_data, $on_error ) = @_;

   my $data;
   my $got_226;

   $self->_connect_dataconn(
      sub {
         my ( $sock ) = @_;

         my $dataconn = IO::Async::Stream->new(
            handle => $sock,
            on_read => sub {
               my ( undef, $buffref, $closed ) = @_;
               return 0 unless $closed;
               $data = $$buffref;
               $got_226 and $on_data->( $data );
               return 0;
            },
         );

         my $loop = $self->get_loop;
         $loop->add( $dataconn );
      },
      $on_error,
      $command,
      {
         '226' => sub {
            $got_226 = 1;
            defined $data and $on_data->( $data );
         },
         err   => sub { $on_error->( "$_[0] ($_[1])" ) },
      },
   );
}

sub _do_command_send_dataconn
{
   my $self = shift;
   my ( $command, $data, $on_done, $on_error ) = @_;

   my $dataconn;

   $self->_connect_dataconn(
      sub {
         my ( $sock ) = @_;

         $dataconn = IO::Async::Stream->new(
            handle => $sock,
            on_read => sub {},
         );

         my $loop = $self->get_loop;
         $loop->add( $dataconn );
      },
      $on_error,
      $command,
      {
         '150' => sub {
            $dataconn->write( $data );
            $dataconn->close_when_empty;
         },
         '226' => sub { $on_done->() },
         err   => sub { $on_error->( "$_[0] ($_[1])" ) },
      },
   );
}

=head2 $ftp->login( %args )

Sends a C<USER> and optionally C<PASS> command. Takes the following arguments:

=over 8

=item user => STRING

Username for the C<USER> command

=item pass => STRING

Password for the C<PASS> command if required

=item on_login => CODE

Continuation to invoke on successful login.

 $on_login->()

=item on_error => CODE

Continuation to invoke on an error.

 $on_error->( $message )

=back

=cut

sub login
{
   my $self = shift;
   my %args = @_;

   my $user = $args{user} or croak "Expected 'user'";

   my $on_login = $args{on_login} or croak "Expected 'on_login'";
   my $on_error = $args{on_error} or croak "Expected 'on_error'";

   $self->do_command( "USER $user",
      331 => sub {
         exists $args{pass} or return $on_error->( "No password" );
         $self->do_command( "PASS $args{pass}",
            230 => sub {
               $on_login->();
            },
            err => sub { $on_error->( "$_[0] ($_[1])" ) },
         );
      },
      err => sub { $on_error->( "$_[0] ($_[1])" ) },
   );
}

=head2 $ftp->rename( %args )

Renames a file on the remote server. Takes the following arguments

=over 8

=item oldpath => STRING

Path to file to rename

=item newpath => STRING

Desired new path for the file

=item on_done => CODE

Continuation to invoke on success.

 $on_done->()

=item on_error => CODE

Continuation to invoke on an error.

 $on_error->( $message )

=back

=cut

sub rename
{
   my $self = shift;
   my %args = @_;

   my $oldpath = $args{oldpath};
   defined $oldpath or croak "Expected 'oldpath'";

   my $newpath = $args{newpath};
   defined $newpath or croak "Expected 'newpath'";

   my $on_done = $args{on_done};
   ref $on_done eq "CODE" or croak "Expected 'on_done' as CODE reference";

   my $on_error = $args{on_error};
   $on_error ||= sub { die "Error $_[0] during rename" };

   $self->do_command( "RNFR $oldpath",
      '350' => sub {
         $self->do_command( "RNTO $newpath",
            ok  => sub { $on_done->() },
            err => sub { $on_error->( "$_[0] ($_[1])" ) },
         );
      },
      'err' => sub { $on_error->( "$_[0] ($_[1])" ) },
   );
}

=head2 $ftp->dele( %args )

Deletes a file on the remote server. Takes the following arguments

=over 8

=item path => STRING

Path to file to delete

=item on_done => CODE

Continuation to invoke on success.

 $on_done->()

=item on_error => CODE

Continuation to invoke on an error.

 $on_error->( $message )

=back

=cut

sub dele
{
   my $self = shift;
   my %args = @_;

   my $path = $args{path};
   defined $path or croak "Expected 'path'";

   my $on_done = $args{on_done};
   ref $on_done eq "CODE" or croak "Expected 'on_done' as CODE reference";

   my $on_error = $args{on_error};
   $on_error ||= sub { die "Error $_[0] during RETR" };

   $self->do_command( "DELE $path",
      ok  => sub { $on_done->() },
      err => sub { $on_error->( "$_[0] ($_[1])" ) },
   );
}

=head2 $ftp->list( %args )

Runs a C<LIST> command on a path on the remote server; which requests details
on the file, or contents of the directory. Takes the following arguments

=over 8

=item path => STRING

Path to C<LIST>

=item on_list => CODE

Continuation to invoke on success. Is passed a list of lines from the C<LIST>
result in a single string.

 $on_list->( $list )

=item on_error => CODE

Continuation to invoke on an error.

 $on_error->( $message )

=back

The C<list_parsed> method may be easier to use as it parses the lines.

=cut

sub list
{
   my $self = shift;
   my %args = @_;

   my $path = $args{path};

   my $on_list = $args{on_list};
   ref $on_list eq "CODE" or croak "Expected 'on_list' as CODE reference";

   my $on_error = $args{on_error};
   $on_error ||= sub { die "Error $_[0] during LIST" };

   $self->_do_command_collect_dataconn(
      "LIST" . ( defined $path ? " $path" : "" ),
      $on_list, $on_error
   );
}

=head2 $ftp->list_parsed( %args )

Runs a C<LIST> command on a path on the remote server; and parse the result
lines. Takes the following arguments

=over 8

=item path => STRING

Path to C<LIST>

=item on_list => CODE

Continuation to invoke on success. Is passed a list of files from the C<LIST>
result, one line per element.

 $on_list->( @list )

=item on_error => CODE

Continuation to invoke on an error.

 $on_error->( $message )

=back

The C<@list> array will be passed a list of C<HASH> references, each formed
like

=over 8

=item name => STRING

The filename

=item type => STRING

A single character; C<f> for files, C<d> for directories

=item size => INT

The size in bytes

=item mtime => INT

The item's last modify timestamp, as a UNIX epoch time

=item mode => INT

The access mode, as a number

=back

=cut

sub list_parsed
{
   my $self = shift;
   my %args = @_;

   my $on_list = $args{on_list};
   ref $on_list eq "CODE" or croak "Expected 'on_list' as CODE reference";

   require File::Listing;

   $self->list(
      path => $args{path},
      on_list => sub {
         my ( $list ) = @_;
         my @files = File::Listing::parse_dir( $list );

         # We want to present a list of HASH refs, as they're nicer to work with
         @files = map { my %h; @h{qw( name type size mtime mode )} = @$_; \%h } @files;

         $on_list->( @files );
      },
      on_error => $args{on_error},
   );
}

=head2 $ftp->nlist( %args )

Runs a C<NLST> command on a path on the remote server; which requests a list
of filenames in a directory. Takes the following arguments

=over 8

=item path => STRING

Path to C<NLST>

=item on_list => CODE

Continuation to invoke on success. Is passed a list of names from the C<NLST>
result in a single string.

 $on_list->( $list )

=item on_error => CODE

Continuation to invoke on an error.

 $on_error->( $message )

=back

The C<namelist> method may be easier to use as it splits the lines.

=cut

sub nlst
{
   my $self = shift;
   my %args = @_;

   my $path = $args{path};

   my $on_list = $args{on_list};
   ref $on_list eq "CODE" or croak "Expected 'on_list' as CODE reference";

   my $on_error = $args{on_error};
   $on_error ||= sub { die "Error $_[0] during NLST" };

   $self->_do_command_collect_dataconn(
      "NLST" . ( defined $path ? " $path" : "" ),
      $on_list, $on_error
   );
}

=head2 $ftp->namelist( %args )

Runs a C<NLST> command on a path on the remote server; which requests a list
of filenames in a directory. Takes the following arguments

=over 8

=item path => STRING

Path to C<NLST>

=item on_names => CODE

Continuation to invoke on success. Is passed a list of names from the C<NLST>
result in a list, one name per entry

 $on_name->( @names )

=item on_error => CODE

Continuation to invoke on an error.

 $on_error->( $message )

=back

=cut

sub namelist
{
   my $self = shift;
   my %args = @_;

   my $on_names = $args{on_names};
   ref $on_names eq "CODE" or croak "Expected 'on_names' as CODE reference";

   $self->nlst(
      path => $args{path},
      on_list => sub {
         my ( $list ) = @_;
         $on_names->( split( m/\r?\n/, $list ) );
      },
      on_error => $args{on_error},
   );
}

sub pasv
{
   my $self = shift;
   my %args = @_;

   my $on_done = $args{on_done};
   ref $on_done eq "CODE" or croak "Expected 'on_done' as CODE reference";

   my $on_error = $args{on_error};
   $on_error ||= sub { die "Error $_[0] during PASV" };

   $self->do_command( "PASV",
      227 => sub {
         my ( $num, $message ) = @_;
         $message =~ m/\((\d+,\d+,\d+,\d+,\d+,\d+)\)/ or return $on_error->( "Did not find (ip,port) in message $message" );

         my ( $ipA, $ipB, $ipC, $ipD, $portHI, $portLO ) = split( m/,/, $1 );

         my $ip   = "$ipA.$ipB.$ipC.$ipD";
         my $port = $portHI*256 + $portLO;

         $on_done->( $ip, $port );
      },
      err => sub { $on_error->( "$_[0] ($_[1])" ) },
   );
}

=head2 $ftp->retr( %args )

Retrieves a file on the remote server. Takes the following arguments

=over 8

=item path => STRING

Path to file to retrieve

=item on_data => CODE

Continuation to invoke on success. Is passed the contents of the file as a
single string.

 $on_data->( $content )

=item on_error => CODE

Continuation to invoke on an error.

 $on_error->( $message )

=back

=cut

sub retr
{
   my $self = shift;
   my %args = @_;

   my $path = $args{path};
   defined $path or croak "Expected 'path'";

   my $on_data = $args{on_data};
   ref $on_data eq "CODE" or croak "Expected 'on_data' as CODE reference";

   my $on_error = $args{on_error};
   $on_error ||= sub { die "Error $_[0] during RETR" };

   $self->_do_command_collect_dataconn(
      "RETR $path",
      $on_data, $on_error
   );
}

=head2 $ftp->stat( %args )

Runs a C<STAT> command on a path on the remote server; which requests details
on the file, or contents of the directory. Takes the following arguments

=over 8

=item path => STRING

Path to C<STAT>

=item on_stat => CODE

Continuation to invoke on success. Is passed a list of lines from the C<STAT>
result, one line per element.

 $on_stat->( @stat )

=item on_error => CODE

Continuation to invoke on an error.

 $on_error->( $message )

=back

The C<stat_parsed> method may be easier to use as it parses the lines.

=cut

sub stat
{
   my $self = shift;
   my %args = @_;

   my $path = $args{path}; # optional

   my $on_stat = $args{on_stat};
   ref $on_stat eq "CODE" or croak "Expected 'on_stat' as CODE reference";

   my $on_error = $args{on_error};
   $on_error ||= sub { die "Error $_[0] during STAT" };

   $self->do_command( defined $path ? "STAT $path" : "STAT",
      '211' => sub {
         my ( $num, $message, $headline, @statlines ) = @_;
         $on_stat->( @statlines );
      },
      'err' => sub { $on_error->( "$_[0] ($_[1])" ) },
   );
}

=head2 $ftp->stat_parsed( %args )

Runs a C<STAT> command on a path on the remote server; and parse the result
lines. Takes the following arguments

=over 8

=item path => STRING

Path to C<STAT>

=item on_stat => CODE

Continuation to invoke on success. Is passed a list of lines from the C<STAT>
result, one line per element.

 $on_stat->( @stat )

=item on_error => CODE

Continuation to invoke on an error.

 $on_error->( $message )

=back

The C<@stat> array will be passed a list of C<HASH> references, each formed
like

=over 8

=item name => STRING

The filename

=item type => STRING

A single character; C<f> for files, C<d> for directories

=item size => INT

The size in bytes

=item mtime => INT

The item's last modify timestamp, as a UNIX epoch time

=item mode => INT

The access mode, as a number

=back

If C<STAT> is invoked on a file, then C<@stat> will contain a single reference
to represent it. If invoked on a directory, the C<@stat> will start with a
reference about the directory itself (whose name will be C<.>), then one per
item in the directory, in the order the server returned the lines.

=cut

sub stat_parsed
{
   my $self = shift;
   my %args = @_;

   defined $args{path} or croak "Expected 'path'";

   my $on_stat = $args{on_stat};
   ref $on_stat eq "CODE" or croak "Expected 'on_stat' as CODE reference";

   require File::Listing;

   my $on_error = $args{on_error};
   $on_error ||= sub { die "Error $_[0] during stat_parsed" };

   $self->stat(
      path => $args{path},
      on_stat => sub {
         my @statlines = @_;

         my @pstats;

         if( @statlines > 1 ) {
            # path is a directory. In that case, look for the . item
            # This would be easy only File::Listing::parse_dir WILL
            # ignore it and we don't get a say in the matter.
            # In this case, we'll do a bit of cheating. We'll look for the
            # "." line ourselves, mangle its name to "DIR", and mangle it
            # back on the other end.

            my @lines_with_cwd;
            my @lines_without_cwd;
            
            foreach ( @statlines ) {
               m/ \.$/ ? ( push @lines_with_cwd, $_ ) : ( push @lines_without_cwd, $_ );
            }

            @lines_with_cwd == 1 or
               return $on_error->( "Did not find '.' in LIST output on directory $args{path}" );

            my $l = $lines_with_cwd[0];
            $l =~ s/ \.$/ DIR/;

            ( my $cwdstat ) = File::Listing::parse_dir( $l );

            $cwdstat->[0] eq "DIR" or
               return $on_error->( "Parsed listing did not contain DIR as the name like we expected for $args{path}" );

            $cwdstat->[0] = ".";

            @pstats = ( $cwdstat, File::Listing::parse_dir( \@lines_without_cwd ) );
         }
         else {
            @pstats = File::Listing::parse_dir( $statlines[0] );
         }

         # We want to present a HASH refs, as they're nicer to work with
         foreach ( @pstats ) {
            my %h;
            @h{qw( name type size mtime mode )} = @$_;
            $_ = \%h;
         }

         $on_stat->( @pstats );
      },
      on_error => $args{on_error},
   );
}

=head2 $ftp->stor( %args )

Stores a file on the remote server. Takes the following arguments

=over 8

=item path => STRING

Path to file to store

=item data => STRING

New contents for the file

=item on_stored => CODE

Continuation to invoke on success.

 $on_stored->()

=item on_error => CODE

Continuation to invoke on an error.

 $on_error->( $message )

=back

=cut

sub stor
{
   my $self = shift;
   my %args = @_;

   my $path = $args{path};
   defined $path or croak "Expected 'path'";

   my $data = $args{data};
   defined $data or croak "Expected 'data'";

   my $on_stored = $args{on_stored};
   ref $on_stored eq "CODE" or croak "Expected 'on_stored' as CODE reference";

   my $on_error = $args{on_error};
   $on_error ||= sub { die "Error $_[0] during STOR" };

   $self->_do_command_send_dataconn(
      "STOR $path",
      $data,
      $on_stored, $on_error
   );
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 SEE ALSO

=over 4

=item *

L<http://tools.ieft.org/html/rfc959> - FILE TRANSFER PROTOCOL (FTP)

=back

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
