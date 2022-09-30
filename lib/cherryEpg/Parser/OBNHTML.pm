package cherryEpg::Parser::OBNHTML;

use 5.024;
use utf8;
use HTML::Entities;
use HTML::Parser;
use Moo;
use Time::Piece;
use Time::Seconds;

extends 'cherryEpg::Parser';

our $VERSION = '0.17';

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
    $parser->{level} = undef;

    $parser->{text}      = undef;
    $parser->{midnight}  = undef;
    $parser->{last}      = undef;
    $parser->{eventList} = [];
    $parser->{errorList} = [];

    $parser->handler( start => \&_start, "self, tagname, attr" );
    $parser->handler( text  => \&_text,  "self, text" );
    $parser->handler( end   => \&_end,   "self, tagname" );

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

    if ( $tagname eq 'div' ) {
        if ( $attr->{class} and $attr->{class} eq 'uk-panel' ) {

            # first step
            $self->{level} = 1;
        } elsif ( $attr->{class}
            and $attr->{class} eq 'uk-margin'
            and $self->{level} == 1 ) {

            # next step
            $self->{level} = 2;
        } else {
            $self->{level} = 0;
        }
    } elsif ( $tagname eq 'strong' and $self->{level} == 2 ) {

        # start of date
        $self->{level} = 3;
        $self->{text}  = "";
    } elsif ( $tagname eq 'p' and $self->{level} > 2 ) {

        # the daily schedule is starting
        $self->{level} += 1;
        $self->{text} = "";
    } elsif ( $tagname eq 'br' and $self->{level} == 5 ) {

        # every event stops with <br>
        _addEvent($self);
    }

} ## end sub _start

sub _text {
    my ( $self, $text ) = @_;

    $self->{text} .= $text;

} ## end sub _text

sub _end {
    my ( $self, $tagname ) = @_;

    if ( $tagname eq 'strong' and $self->{level} == 3 ) {

        # this is the date
        if ( $self->{text} =~ /,.(\d+\.\d+\.\d+)\./ ) {
            my $date = $1;
            $self->{midnight} = localtime->strptime( $date, "%d.%m.%Y" );

            # last added event
            $self->{last} = 0;
        } else {
            $self->{midnight} = undef;
        }
        $self->{level} = 4;
    } elsif ( $tagname eq 'p' and $self->{level} == 5 ) {
        _addEvent($self);
    }

} ## end sub _end

sub _addEvent {
    my ($self) = @_;
    my $text = $self->{text};

    # remove some stuff
    decode_entities($text);

    if ( $text =~ m/(\d+)\.(\d+) (.*?), (.*)$/ ) {
        my $hour     = $1;
        my $min      = $2;
        my $title    = $3;
        my $subtitle = $4 // "";

        my $start = $self->{midnight} + ONE_HOUR * $hour + ONE_MINUTE * $min;

        # correct after midnight
        if ( $start < $self->{last} ) {
            $start += ONE_DAY;
        }
        $self->{last} = $start;

        # Add the event
        my $event = {
            start    => $start->epoch,
            title    => $title,
            subtitle => $subtitle,
        };
        push( @{ $self->{eventList} }, $event );
    } ## end if ( $text =~ m/(\d+)\.(\d+) (.*?), (.*)$/)

    $self->{text} = "";

} ## end sub _addEvent

=head1 AUTHOR

This software is copyright (c) 2019 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
