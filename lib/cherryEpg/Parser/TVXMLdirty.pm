package cherryEpg::Parser::TVXMLdirty;
use 5.010;
use utf8;
use Moo;
use strictures 2;
use XML::Parser::PerlSAX;

extends 'cherryEpg::Parser';

our $VERSION = '0.18';

sub BUILD {
    my ( $self, $arg ) = @_;

    $self->{report}{parser} = __PACKAGE__;
}

=head3 parse( $parserOption)

Do the file processing and return a reference to hash with keys
- errorList => array with troubles during parsing
- programme => hash of arrays of events found

The XMLTV format can contain multiple programme schedules.

Please be carefull programme = channel here.

When multiple programme are defined the first element in $parserOption should contain the channel name e.g.
channel => "htv1.tv.hrt.hr" to select a programme.
If there is only a single programmee defined in the file no channel option is required.

This "dirty" parser is not strict regarding time format therefore also
start="20210220023000 +00:00" is accepted.
Language priority can be defined, therefore also $parserOption is used.

$parserOption contains two values separated by comma {channel},{language} e.g.

htv1.tv.hrt.hr,cro
,ger
bbc

=cut

sub parse {
    my ( $self, $parserOption ) = @_;
    my $report = $self->{report};

    # get values
    my ( $channel, $language ) = split( /,/, $parserOption // '' );

    my $handler = TVXMLdirtyHandler->new($language);
    my $parser  = XML::Parser::PerlSAX->new(
        Handler => $handler,
        output  => $report
    );

    $parser->parse( Source => { SystemId => $self->{source} } );

    # now we have multiple channels, let's select the requested one
    if ($channel) {

        # select by parser option
        if ( $report->{channel}{$channel} ) {
            $report->{eventList} = $report->{channel}{$channel}{eventList};
            $report->{option}    = $channel;
            delete $report->{channel};
        } else {
            push( @{ $report->{errorList} }, "incorrect channel selection" );
        }
    } elsif ( scalar( keys( %{ $report->{channel} } ) ) == 1 ) {

        # if there is just a single channel we asume it's the right one
        my $channel = ( values( %{ $report->{channel} } ) )[0];
        $report->{eventList} = $channel->{eventList};
        delete $report->{channel};
    } elsif ( scalar( keys( %{ $report->{channel} } ) ) == 0 ) {
        push( @{ $report->{errorList} }, "no valid events" );
    } else {
        push( @{ $report->{errorList} }, "missing channel selection after parser" );
    }

    return $report;
} ## end sub parse

package TVXMLdirtyHandler;
use strict;
use warnings;
use Time::Piece;
use Try::Tiny;
use Carp qw( croak );

sub new {
    my ( $this, $language ) = @_;
    my $class = ref($this) || $this;

    # set primary language od default
    my $self = { language => $language // 'en', };

    bless( $self, $class );
    return $self;
} ## end sub new

sub start_document {
    my ($self) = @_;

    # here we will store all program hashes
    $self->{channel} = {};

    # and the possible error list
    $self->{errorList} = [];
} ## end sub start_document

sub end_document {
    my ( $self, $element ) = @_;

    $self->{report} = $self->{'_parser'}->{output};

    # return all built program lists
    $self->{report}{channel}   = $self->{channel};
    $self->{report}{errorList} = $self->{errorList};
} ## end sub end_document

sub decode_timestamp {
    my ( $self, $t ) = @_;

    return if !$t;
    $t =~ s/://;
    try {
        Time::Piece->strptime( $t, "%Y%m%d%H%M%S %z" )->epoch;
    };
} ## end sub decode_timestamp

sub start_element {
    my ( $self, $element ) = @_;

    if ( $element->{Name} eq 'programme' ) {
        my $event = {};

        # save start and stop
        # ISO 8601
        $event->{start} = $self->decode_timestamp( $element->{Attributes}{start} );

        # stop can be also end
        $event->{stop} = $self->decode_timestamp( $element->{Attributes}{stop} )
            // $self->decode_timestamp( $element->{Attributes}{end} );

        $event->{channel} = $element->{Attributes}{channel};

        $self->{currentEvent} = $event;
    } ## end if ( $element->{Name} ...)

    # store current language
    if ( $element->{Attributes}{lang} ) {
        $self->{currentLang} = $element->{Attributes}{lang};
    } else {
        $self->{currentLang} = undef;
    }

    $self->{currentData} = "";
} ## end sub start_element

sub characters {
    my ( $self, $element ) = @_;

    $self->{currentData} .= $element->{Data};
}

sub end_element {
    my ( $self, $element ) = @_;
    my $value = $self->{currentData};
    my $event = $self->{currentEvent};
    my $lang  = $self->{currentLang};

    $self->{linecount} = $self->{_parser}->location()->{'LineNumber'};

SWITCH: for ( $element->{Name} ) {
        /programme/i && do {

            # add the event to the list
            $self->mapLang();
            $self->addEvent();
            return;
        };
        /^title/ && do {

            if ($lang) {
                $event->{lang}{$lang}{title} = $value;
            } else {
                $event->{title} = $value;
            }
            return;
        };
        /sub-title/ && do {

            if ($lang) {
                $event->{lang}{$lang}{subtitle} = $value;
            } else {
                $event->{subtitle} = $value;
            }
            return;
        };
        /desc/i && do {

            if ($lang) {
                $event->{lang}{$lang}{synopsis} = $value;
            } else {
                $event->{synopsis} = $value;
            }
            return;
        };
        /parentalrating/ && do {
            if ( $value =~ /(\d+)/ ) {
                $value = $1 + 3;
            } else {
                $self->_error( "parental_rating_descriptor not numeric [$value] in line " . $self->{linecount} );
                return;
            }

            if ($lang) {
                $event->{lang}{$lang}{parental_rating} = $value;
            } else {
                $event->{parental_rating} = $value;
            }
            return;
        };
    } ## end SWITCH: for ( $element->{Name} )
    return;
} ## end sub end_element

sub set_document_locator {
    my ( $self, $params ) = @_;
    $self->{'_parser'} = $params->{'Locator'};
}

sub _error {
    my $self = shift;

    push( @{ $self->{errorList} }, sprintf( shift, @_ ) );
}

sub mapLang {
    my $self  = shift;
    my $event = $self->{currentEvent};
    my $lang  = $self->{language};

    # try to use the selected language
    foreach my $key (qw( title subtitle synopsis parental_rating)) {
        $event->{$key} = $event->{lang}{$lang}{$key} if exists $event->{lang}{$lang}{$key};
    }
    delete $event->{lang}{$lang};

    my $alternativeSubtitle;

    # if missing try other languages in alpabetical order but 'en' first
    foreach my $lang ( sort { return -1 if $a eq 'en'; return 1 if $b eq 'en'; ( $a cmp $b ) } keys %{ $event->{lang} } ) {
        foreach my $key (qw( title subtitle synopsis parental_rating)) {
            $event->{$key} = $event->{lang}{$lang}{$key} if exists $event->{lang}{$lang}{$key} && !exists $event->{$key};

            # use titla from other language as alternative subtitle
            if ( $key eq 'title' && exists $event->{lang}{$lang}{$key} && !$alternativeSubtitle ) {
                $alternativeSubtitle = $event->{lang}{$lang}{$key};
            }
        } ## end foreach my $key (qw( title subtitle synopsis parental_rating))
        delete $event->{lang}{$lang};
    } ## end foreach my $lang ( sort { return...})

    delete $event->{lang} if exists $event->{lang};

    $event->{subtitle} = $alternativeSubtitle if $alternativeSubtitle && !exists $event->{subtitle};

    return 1;
} ## end sub mapLang

sub addEvent {
    my $self  = shift;
    my $event = $self->{currentEvent};

    # check if all event data is complete and valid
    my @missing;
    push( @missing, "start" )   unless $event->{start};
    push( @missing, "title" )   unless $event->{title};
    push( @missing, "channel" ) unless defined $event->{channel};
    push( @missing, "stop" )    unless $event->{stop};

    if ( scalar @missing > 0 ) {
        $self->_error( "missing or incorrect input data [" . join( ' ', @missing ) . "] line " . $self->{linecount} );
        return;
    }

    my $channel = $event->{channel};
    delete $event->{channel};

    # push to final array
    push( $self->{channel}{$channel}{eventList}->@*, $event );

    return 1;
} ## end sub addEvent

=head1 AUTHOR

This software is copyright (c) 2019-2022 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
