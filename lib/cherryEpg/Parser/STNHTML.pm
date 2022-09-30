package cherryEpg::Parser::STNHTML;

use 5.024;
use utf8;
use HTML::Parser;
use Moo;
use Time::Piece;
use Time::Seconds;

extends 'cherryEpg::Parser';

our $VERSION = '0.23';

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

    $parser->{now}              = localtime;
    $parser->{weekday}          = {};          # the weekdays starting from 0 - Mon, 1 - Tue ...
    $parser->{navField}         = undef;
    $parser->{tabField}         = undef;
    $parser->{timeField}        = undef;
    $parser->{titleField}       = undef;
    $parser->{episodeField}     = undef;
    $parser->{descriptionField} = undef;
    $parser->{currentEvent}     = undef;
    $parser->{eventList}        = [];
    $parser->{errorList}        = [];

    $parser->handler( start => \&_start, "self, tagname, attr" );
    $parser->handler( text  => \&_text,  "self, text" );
    $parser->handler( end   => \&_end,   "self, tagname" );

    $parser->unbroken_text(1);

    if ( open( my $fh, "<:utf8", $self->{source} ) ) {

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

    if ( $tagname eq 'a' ) {

        # take number from #tab1
        if ( $attr->{href} =~ m/#tab(\d)/ ) {
            $self->{navField} = $1;
        } else {
            $self->{navField} = 0;
        }

    } ## end if ( $tagname eq 'a' )

    if ( $tagname eq 'div' ) {
        if ( exists $attr->{id} and $attr->{id} =~ m/tab(\d)/ ) {

            # start of event block
            $self->{tabField} = $1;
        } elsif ( exists $attr->{class} and $attr->{class} eq 'time' ) {

            # this is the event time
            $self->{timeField} = 1;
        } else {
            $self->{timeField} = undef;
        }
    } ## end if ( $tagname eq 'div')

    if ( $tagname eq 'strong' and $attr->{class} and $attr->{class} eq 'title' ) {

        # the title follows
        $self->{titleField} = 1;
    } else {
        $self->{titleField} = 0;
    }

    if ( $tagname eq 'span' and $attr->{class} and $attr->{class} eq 'episode' ) {

        # the episode follows
        $self->{episodeField} = 1;
    } else {
        $self->{episodeField} = 0;
    }

    if ( $tagname eq 'p' and $attr->{class} and $attr->{class} eq 'description' ) {

        # the description follows
        $self->{descriptionField} = 1;
    } else {
        $self->{descriptionField} = 0;
    }
} ## end sub _start

sub _text {
    my ( $self, $text ) = @_;

    $self->{text} = $text;

} ## end sub _text

sub _end {
    my ( $self, $tagname ) = @_;

    if ( $tagname eq 'span' and $self->{navField} ) {

        # only trigger on day.month
        if ( $self->{text} =~ m/(\d{2})\.(\d{2})/ ) {

            my $month = $2;
            my $day   = $1;
            my $year  = $self->{now}->year;

            my $t = localtime->strptime( "$year/$month/$day", "%Y/%m/%d" );

            if ( ( $self->{now} - $t ) > ONE_MONTH ) {

                # if we are around new year increase year
                $year += 1;
                $t = Time::Piece->strptime( "$year/$month/$day", "%Y/%m/%d" );
            } ## end if ( ( $self->{now} - ...))

            $self->{weekday}{ $self->{navField} } = $t;
        } ## end if ( $self->{text} =~ ...)
    } elsif ( $tagname eq 'a' ) {
        $self->{navField} = undef;
    } elsif ( $tagname eq 'div' ) {
        if ( $self->{timeField} ) {
            $self->{currentEvent} = { time => $self->{text} };
        }
    } elsif ( $tagname eq 'strong' ) {
        if ( $self->{titleField} ) {
            $self->{currentEvent}{title} = $self->{text};
        }
    } elsif ( $tagname eq 'span' ) {
        if ( $self->{episodeField} ) {
            $self->{currentEvent}{episode} = $self->{text};
        }
    } elsif ( $tagname eq 'p' ) {
        if ( $self->{descriptionField} ) {
            $self->{currentEvent}{description} = $self->{text};
            _addEvent($self);
        }
    } ## end elsif ( $tagname eq 'p' )

} ## end sub _end

sub _addEvent {
    my ($self) = @_;

    if ( $self->{currentEvent}{time} !~ m/\s*(\d+):(\d+)\s/ ) {
        push( @{ $self->{errorList} }, "Incorrect time format [" . $self->{currentEvent}{time} . "]" );
        return;
    }

    my $hour   = $1;
    my $minute = $2;
    my $date   = $self->{weekday}{ $self->{tabField} }->ymd;

    # the time in the HTML is localtime we need to convert to UTC
    my $t = localtime->strptime( "$date $hour:$minute", "%Y-%m-%d %H:%M" );

    my $event = {
        start    => $t->epoch,
        title    => $self->{currentEvent}{title},
        subtitle => $self->{currentEvent}{episode},
        synopsis => $self->{currentEvent}{description},
    };

    push( @{ $self->{eventList} }, $event );
} ## end sub _addEvent

=head1 AUTHOR

This software is copyright (c) 2019 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
