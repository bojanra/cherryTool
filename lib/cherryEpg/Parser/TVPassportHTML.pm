package cherryEpg::Parser::TVPassportHTML;
use 5.010;
use utf8;
use Moo;
use strictures 2;
use HTML::Parser;
use Time::Piece;
use Time::Seconds;
use Try::Tiny;

extends 'cherryEpg::Parser';

our $VERSION = '0.10';

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
    my ( $self, $option ) = @_;
    my $report = $self->{report};

    my $parser = HTML::Parser->new( api_version => 3 );

    # this is used for depth counting
    $parser->{eventList} = [];
    $parser->{errorList} = [];

    $parser->handler( start => \&_start, "self, tagname, attr" );

    $parser->unbroken_text(1);

    if ( open( my $fh, "<:utf8", $self->{source} ) ) {
        $self->logger->trace( "parse " . $self->{source} );

        my $r = $parser->parse_file($fh);
        close($fh);

        $report->{eventList} = $r->{eventList};
        $report->{errorList} = $r->{errorList};
    } else {
        $report->{errorList} = ["Error opening file: $!"];
    }

    return $report;
} ## end sub parse

sub _start {
    my ( $self, $tagname, $attr ) = @_;

    if ( $tagname eq 'div' && exists $attr->{id} && $attr->{id} =~ /^itemheader\d+$/ ) {
        my $event = {};

        $event->{start} = try {
            localtime->strptime( $attr->{'data-listdatetime'}, "%Y-%m-%d %H:%M:%S" )->epoch;
        } catch {
            push( @{ $self->{errorList} }, "Incorrect time format [" . $attr->{'data-listdatetime'} . "]" );
        };
        return if !$event->{start};

        $event->{duration} = try {
            $attr->{'data-duration'} * 60;
        } catch {
            return undef;
        };

        if ( $attr->{'data-showname'} ne "" && $attr->{'data-showname'} ne "Movie" ) {
            $event->{title} = $attr->{'data-showname'};
        } else {
            $event->{title} = $attr->{'data-episodetitle'};
        }

        $event->{subtitle} = $attr->{'data-showtype'};
        if ( $attr->{'data-year'} ne "" ) {
            if ( $event->{subtitle} ne "" ) {
                $event->{subtitle} .= ", " . $attr->{'data-year'};
            } else {
                $event->{subtitle} = $attr->{'data-year'};
            }
        } ## end if ( $attr->{'data-year'...})
        $event->{synopsis} = $attr->{'data-description'};

        # Add the event
        push( @{ $self->{eventList} }, $event );
    } ## end if ( $tagname eq 'div'...)
} ## end sub _start

=head1 AUTHOR

This software is copyright (c) 2020 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
