package cherryEpg::Parser::TVPHTML;

use 5.024;
use utf8;
use HTML::Entities;
use HTML::Parser;
use JSON::XS;
use Moo;
use Try::Tiny;
use open ':std', ':encoding(utf8)';

extends 'cherryEpg::Parser';

our $VERSION = '0.11';

our $logger;

sub BUILD {
    my ( $self, $arg ) = @_;

    $self->{report}{parser} = __PACKAGE__;
}

=head3 parse( $parserOption)

Parse the file and return a reference to hash with keys
- errorList => array with troubles during parsing
- eventList => array of events found

=cut

sub parse {
    my ( $self, $parserOption ) = @_;
    my $report = $self->{report};

    # not very elegant but required for tracing outside of this object
    $logger = $self->{logger};

    my $parser = HTML::Parser->new( api_version => 3 );

    # this is used for depth counting
    $parser->{level} = 0;

    $parser->{offset}       = 0;
    $parser->{xChangeTitle} = 0;
    $parser->{getEnglish}   = 0;

    $parser->{text} = undef;

    $parser->{eventList} = [];
    $parser->{errorList} = [];

    $parser->handler( start => \&_start, "self, tagname, attr" );
    $parser->handler( text  => \&_text,  "self, text" );
    $parser->handler( end   => \&_end,   "self, tagname" );

    $parser->unbroken_text(1);

    if ( open( my $fh, "<:utf8", $self->{source} ) ) {
        $self->logger->trace( "parse " . $self->{source} );

        $parser->parse_file($fh);
        close($fh);

        $report->{eventList} = $parser->{eventList};
        $report->{errorList} = $parser->{errorList};
    } else {
        $report->{errorList} = ["Error opening file: $!"];
    }

    return $report;
} ## end sub parse

sub _start {
    my ( $self, $tagname, $attr ) = @_;

    if ( $tagname eq 'script' && $attr->{type} && $attr->{type} eq 'text/javascript' ) {
        $self->{level} = 1;
    }
} ## end sub _start

sub _text {
    my ( $self, $text ) = @_;

    $text =~ s/^\s+//g;
    $self->{text} = $text;

} ## end sub _text

sub _end {
    my ( $self, $tagname ) = @_;
    use Data::Dumper;

    if ( $self->{level} && $tagname eq 'script' ) {
        $self->{level} = 0;
        if ( $self->{text} =~ /\s*window\.__stationsProgram.*?=\s*(.*);[\s\n]*$/s ) {

            my $content = $1;
            my $json    = try { JSON::XS->new->utf8->decode($content); };

            if ( $json && ref($json) eq 'HASH' ) {
                foreach my $item ( @{ $json->{items} } ) {

                    # Add the event
                    my $event = {
                        start => $item->{date_start} / 1000,
                        stop  => $item->{date_end} / 1000,
                        title => decode_entities( $item->{title} ),
                    };

                    if ( $item->{program} && $item->{program}{description_long} ) {
                        $event->{synopsis} = $item->{program}{description_long};
                    }
                    if ( exists $item->{plrating} ) {
                        my $plrating = $item->{plrating};

                        if ( $plrating == 4 ) {
                            $event->{parental_rating} = 12 - 3;
                        } elsif ( $plrating == 3 ) {
                            $event->{parental_rating} = 7 - 3;
                        } elsif ( $plrating == 1 ) {
                            $event->{parental_rating} = 16 - 3;
                        }
                    } ## end if ( exists $item->{plrating...})

                    push( @{ $self->{eventList} }, $event );
                } ## end foreach my $item ( @{ $json...})
            } ## end if ( $json && ref($json...))
        } ## end if ( $self->{text} =~ ...)
    } ## end if ( $self->{level} &&...)
} ## end sub _end

=head1 AUTHOR

This software is copyright (c) 2021 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
