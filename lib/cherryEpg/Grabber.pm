package cherryEpg::Grabber;

use 5.024;
use utf8;
use File::Basename;
use File::Glob ':nocase';
use File::Rsync;
use Log::Log4perl qw(get_logger);
use Moo;
use Net::Curl::Easy qw(:constants );
use Path::Class;
use Time::Piece;
use Time::Seconds;
use Try::Tiny;
use URI::Escape;
use URI;

my $CURLOPT_TIMEOUT = 60;

my $logger = get_logger('grabber');

has channel => (
    is       => 'ro',
    required => 1,
    isa      => sub {
        die "channel_id, url and grabber must be defined"
            unless exists $_[0]->{grabber}{url}
            and exists $_[0]->{channel_id};
    }
);

has 'cherry' => ( is => 'lazy', );

sub _build_cherry {
    my ($self) = @_;

    return cherryEpg->instance();
}

sub BUILD {
    my ( $self, $args ) = @_;

    $self->{channel_id} = $self->channel->{channel_id};
    $self->{url}        = $self->channel->{grabber}{url};
    $self->{days}       = $self->channel->{grabber}{days} // 1;
    if ( exists $self->channel->{grabber}{filename} ) {
        $self->{filename} = $self->channel->{grabber}{filename};
    }
    $self->{source}      = $self->cherry->config->{core}{stock};
    $self->{destination} = dir( $self->cherry->config->{core}{ingest}, $self->{channel_id} );

    mkdir( $self->{destination} ) if !-d $self->{destination};
} ## end sub BUILD

=head3 grab( )

Get files from remote/local via url of type 'http|ftp|rsync'.
The url is parsed through strftime on http and ftp requests for n days.

=cut

sub grab {
    my ($self) = @_;

    if ( !-d $self->{destination} ) {
        $logger->error( "destination [$self->{destination}]", $self->{channel_id} );
    }

    # decide which scheme to use
    # default scheme is rsync (smart copy tool)
    if ( $self->{url} !~ m|://| ) {
        $self->{url} = "rsync://" . $self->{url};
        $logger->trace( "using rsync method", $self->{channel_id} );
    }

    $self->{uri} = URI->new( $self->{url} );
    my $scheme = $self->{uri}->scheme();

    if ( !$scheme ) {
        $logger->error( "unsupported url scheme $self->{url}", $self->{channel_id} );
        return;
    }

    if ( !exists $self->{filename} or $self->{filename} eq "" ) {
        $self->{uri}->path() =~ m|/([^/]*)$|;
        my $last = $1;
        if ( $last && length($last) > 0 ) {
            $self->{filename} = $last;
        } else {
            $self->{filename} = 'file%Y%m%d';
        }
    } ## end if ( !exists $self->{filename...})

    my $result;
    for ($scheme) {
        /ftp/i && do {
            $result = $self->_curl();
            next;
        };
        /http/i && do {
            $result = $self->_curl();
            next;
        };
        /rsync/i && do {
            $result = $self->_rsync();
            next;
        };
        $logger->error( "method not yet supported [$_]", $self->{channel_id} );
        return;
    } ## end for ($scheme)

    return $result;
} ## end sub grab

=head3 move( $source, $filename)

Move $source file to ingest directory with $filename.
Return 1 on success.

=cut

sub move {
    my ( $self, $source, $filename ) = @_;

    my $filePath = file( $self->{destination}, $filename );

    return unless -e $source;

    if ( rename( $source, $filePath ) ) {
        $logger->info( "import file [$filename]", $self->{channel_id}, undef );
        return 1;
    } else {
        $logger->error( "import file [$filename]", $self->{channel_id}, undef );
        return;
    }
} ## end sub move

=head3 _rsync()

Do the real rsync stuff on arg.

=cut

sub _rsync {
    my ($self) = @_;

    my $opaque = $self->{url};
    $opaque =~ s|^rsync://||i;

    my $source = file( $self->{source}, $opaque );

    # escape spaces
    $source =~ s/ /\\ /g;

    # do globbing
    my (@files) = glob($source);

    if ( !scalar @files ) {
        $logger->warn( "no source path/files for rsync [$source]", $self->{channel_id} );
        return [];
    }

    foreach (@files) {
        $_ = uri_unescape($_);
        $logger->trace( "sync source [$_]", $self->{channel_id} );
    }

    my $rsync = File::Rsync->new(
        recursive => 1,
        times     => 1,
        perms     => 1,
        group     => 1,
        owner     => 1,
        verbose   => 2,
        src       => \@files,
        dest      => $self->{destination}
    );

    $logger->trace( "sync target [$self->{destination}]", $self->{channel_id} );

    my $status = $rsync->exec();

    # restore in/out encoding
    binmode( STDOUT, ':encoding(UTF-8)' );

    if ( !$status || $rsync->status != 0 ) {
        $logger->error( "rsync rc=" . $rsync->status, $self->{channel_id}, undef, \@files );
        return [];
    }

    my (@report) = $rsync->out;

    # remove first lines not containing files
    splice( @report, 0, 2 );
    splice( @report, -4 );

    chomp @report;
    my @justFiles = grep { !/\/$/ } @report;

    my @changed  = grep { !/uptodate/ } @justFiles;
    my @allFiles = map  {s/ is uptodate//} @justFiles;

    $logger->info( "rsync files [" . scalar(@changed) . "/" . scalar(@justFiles) . "]", $self->{channel_id}, undef, \@justFiles );
    return \@justFiles;
} ## end sub _rsync

=head3 _curl()

Do the real curl stuff.
This is handling ftp and http.

=cut

sub _curl {
    my ($self) = @_;
    my @result;
    my $now  = localtime;
    my $days = $self->{days};

    my @previousRequests;

    # only do multiple days if url contains "%"
    if ( $self->{url} !~ /%/ ) {
        $days = 1;
    } else {
        $logger->debug( "curl fetch [$days] days", $self->{channel_id} );
    }

    for ( my $i = 0 ; $i < $days && $i < 10 ; $i++ ) {

        my $moment = $now + $i * ONE_DAY;
        my $url    = $moment->strftime( $self->{url} );

        # skip new request if url has been already fetched
        my $skip;
        foreach (@previousRequests) {
            if ( $_ eq $url ) {
                $skip = 1;
                last;
            }
        } ## end foreach (@previousRequests)
        next if $skip;
        push( @previousRequests, $url );

        # apply uriescape only to the part after ? and only the cgi values
        if ( $url =~ m/^(.*?)\?(.*)$/ ) {
            my $path = $1;
            my @e    = split( /\&/, $2 );
            @e   = map { my ( $k, $v ) = split(/\=/); $k . '=' . uri_escape($v); } @e;
            $url = $path . "?" . join( '&', @e );
        } ## end if ( $url =~ m/^(.*?)\?(.*)$/)

        my $urlEscaped = $url;

        # replace space with %20
        # uri_escape of the whole string
        $urlEscaped =~ s/ /%20/g;

        $logger->trace( "fetch [$url]", $self->{channel_id} );

        my $response_body;
        my $response_header;

        my $curl = Net::Curl::Easy->new();
        $curl->setopt( CURLOPT_URL,            $urlEscaped );
        $curl->setopt( CURLOPT_TIMEOUT,        $CURLOPT_TIMEOUT );
        $curl->setopt( CURLOPT_FOLLOWLOCATION, 3 );
        $curl->setopt( CURLOPT_MAXREDIRS,      5 );
        $curl->setopt( CURLOPT_WRITEDATA,      \$response_body );
        $curl->setopt( CURLOPT_USERAGENT,      "Net::Curl/$Net::Curl::VERSION" );
        $curl->setopt( CURLOPT_HEADERDATA,     \$response_header );

        my $success = try {
            $curl->perform();
            return 1;
        } catch {
            $response_body = undef;
            $logger->error( "curl aborted [$_]", $self->{channel_id}, undef, [$url] );
            return 0;
        };

        next if !$success;

        my $responseCode = $curl->getinfo(CURLINFO_RESPONSE_CODE);

        if ( $self->{uri}->scheme() eq 'http' && $responseCode != 200 ) {
            $logger->error( "received [$responseCode]", $self->{channel_id}, undef, [$url] );
            next;
        }

        my $filename;
        if ( $response_header && $response_header =~ /^Content-Disposition: .*filename="(.+)"/m ) {
            $filename = $1;
        } else {

            # Some source have the date in the path before the filename,
            # therefore we need to include the complete path in the new filename
            my $u        = URI->new($url);
            my $query    = $u->query    // '';
            my $fragment = $u->fragment // '';
            my $path     = $u->path;
            $filename = $path . $query . $fragment;
            $filename =~ s|^/||;
            $filename =~ tr|/|_|;
        } ## end else [ if ( $response_header ...)]

        # there is no filename defined, take something default
        if ( !$filename or $filename eq "" ) {
            $filename = "index.html";
            $logger->debug( "use default filename", $self->{channel_id} );
        }

        my $filePath = file( $self->{destination}, $filename );

        if ( !$self->_writeFile( $filePath, $response_body ) ) {
            $logger->error( "write [$filename]", $self->{channel_id} );
            next;
        }

        push( @result, "$url => $filename" );
    } ## end for ( my $i = 0 ; $i < ...)

    $logger->info( "curl fetch file [" . scalar(@result) . "]", $self->{channel_id}, undef, \@result );
    return \@result;
} ## end sub _curl

=head3 _writefile( $filepath, $content)

Write $content to $filepath

=cut

sub _writeFile {
    my ( $self, $filepath, $content ) = @_;

    $content = '' unless $content;

    return 0 unless open( my $out, ">", $filepath );

    print( $out $content );
    close($out);

    return 1;
} ## end sub _writeFile

=head1 AUTHOR

This software is copyright (c) 2022 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
