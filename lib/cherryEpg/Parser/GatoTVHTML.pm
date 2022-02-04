package cherryEpg::Parser::GatoTVHTML;
use 5.010;
use utf8;
use Moo;
use strictures 2;
use HTML::Parser;
use HTML::Entities;
use Time::Piece;
use Time::Seconds;

extends 'cherryEpg::Parser';

our $VERSION = '0.21';

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

    my $parser = HTML::Parser->new( api_version => 3 );

    # this is used for depth counting
    $parser->{level} = 0;

    $parser->{offset} = 0;

    # use the parser option as offset
    if ( $parserOption && $parserOption =~ /^[+-]?\d+$/ ) {
        $parser->{offset} = $parserOption * ONE_HOUR;
    }

    $parser->{text} = undef;

    $parser->{eventList} = [];
    $parser->{errorList} = [];

    # get date from file name
    if ( $self->{source} =~ /(\d{4}-\d{2}-\d{2})$/ ) {
        $parser->{date} = $1;
    } else {
        push( @{ $report->{errorList} }, "Filename contains no date" );
        return $report;
    }

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
        if (    $attr->{class}
            and $attr->{class} eq 'div_program_title_on_channel'
            and $self->{level} == 2 ) {

            $self->{level} += 1;
        } elsif ( $attr->{class} and $attr->{class} eq 'div_episode_deporte_on_channel' and $self->{level} == 4 ) {

            $self->{text} = "";
            $self->{level} += 1;
        }
    } elsif ( $tagname eq 'tr' and $attr->{class} and $attr->{class} =~ m/tbl_EPG_row/ ) {

        # first step
        $self->{level}    = 1;
        $self->{subtitle} = '';
    } elsif ( $tagname eq 'time' and $self->{level} == 1 ) {

        # find start time
        if ( $attr->{datetime} =~ /(\d\d:\d\d)/ ) {
            $self->{start} = localtime->strptime( $self->{date} . ' ' . $1, "%Y-%m-%d %H:%M" );
            $self->{level} += 1;
        }
    } elsif ( $tagname eq 'time' and $self->{level} == 2 ) {

        # stop time
        if ( $attr->{datetime} =~ /(\d\d:\d\d)/ ) {
            $self->{stop} = localtime->strptime( $self->{date} . ' ' . $1, "%Y-%m-%d %H:%M" );

            $self->{level} += 1;
        }
    } elsif ( $tagname eq 'span' and $self->{level} == 3 ) {

        # title
        $self->{text} = "";
    }

} ## end sub _start

sub _text {
    my ( $self, $text ) = @_;

    $self->{text} .= $text;

} ## end sub _text

sub _end {
    my ( $self, $tagname ) = @_;

    if ( $tagname eq 'span' and $self->{level} == 3 ) {

        $self->{title} = decode_entities( $self->{text} );
        $self->{level} += 1;
    } elsif ( $tagname eq 'tr' and $self->{level} >= 4 ) {
        _addEvent($self);
        $self->{level} = 0;
    } elsif ( $tagname eq 'div' and $self->{level} == 5 ) {

        $self->{subtitle} = decode_entities( $self->{text} );
        $self->{level} += 1;
    }

} ## end sub _end

sub _addEvent {
    my ($self) = @_;

    # use the offset
    if ( $self->{offset} ) {
        $self->{start} += $self->{offset};
        $self->{stop}  += $self->{offset};
    }

    # correct date change
    if ( $self->{start} > $self->{stop} ) {
        $self->{stop} += ONE_DAY;
    }

    # Add the event
    my $event = {
        start => $self->{start}->epoch,
        stop  => $self->{stop}->epoch,
        title => $self->{title},
    };

    if ( $self->{subtitle} and $self->{subtitle} ne '' ) {
        $event->{subtitle} = $self->{subtitle};
    }

    push( @{ $self->{eventList} }, $event );

} ## end sub _addEvent

=head1 AUTHOR

This software is copyright (c) 2021 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
