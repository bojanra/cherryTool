package cherryEpg::Parser::ProPlusXML;
use 5.010;
use utf8;
use Moo;
use strictures 2;
use XML::Parser::PerlSAX;

extends 'cherryEpg::Parser';

our $VERSION = '0.23';

sub BUILD {
    my ( $self, $arg ) = @_;

    $self->{report}{parser} = __PACKAGE__;
}

=head3 parse( $parserOption)

Do the file processing and return a reference to hash with keys
- errorList => array with troubles during parsing
- eventList => array of events found

=cut

sub parse {
    my ( $self, $option ) = @_;
    my $report = $self->{report};

    my $handler = ProPlusXMLHandler->new();
    my $parser  = XML::Parser::PerlSAX->new(
        Handler => $handler,
        output  => $report
    );

    $parser->parse( Source => { SystemId => $self->{source} } );

    return $report;
} ## end sub parse

package ProPlusXMLHandler;
use strict;
use warnings;
use Time::Piece;
use Time::Seconds;
use Carp qw( croak );

sub new {
    my $this  = shift;
    my $class = ref($this) || $this;
    my $self  = {};

    bless( $self, $class );
    return $self;
} ## end sub new

sub start_document {
    my ($self) = @_;

    # this will be the events array
    $self->{eventList} = [];

    # and the possible error list
    $self->{errorList} = [];
} ## end sub start_document

sub end_document {
    my ($self) = @_;

    $self->{report}            = $self->{'_parser'}->{output};
    $self->{report}{eventList} = $self->{eventList};
    $self->{report}{errorList} = $self->{errorList};
} ## end sub end_document

sub start_element {
    my ( $self, $element ) = @_;

    if ( $element->{Name} =~ /event/i ) {
        $self->{currentEvent} = {};

        # take the eventId from event attribute ID in form "V289187" or "9879878" letter+number or just number
        if ( defined $element->{Attributes}{ID} && $element->{Attributes}{ID} =~ m/\D?(\d+)/ ) {
            $self->{currentEvent}{id} = $1 & 0xffff;
        }
    } ## end if ( $element->{Name} ...)

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

    $self->{linecount} = $self->{_parser}->location()->{'LineNumber'};

SWITCH: for ( $element->{Name} ) {
        /epg/i && do {
            return;
        };
        /^event$/i && do {
            $self->addEvent();
            return;
        };
        /^channelname$/i && do {
            $value =~ s/ /-/g;
            $self->{channel_id} ||= lc($value);
            return;
        };
        /^start/i && do {
            if ( $value =~ /^(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)$/ ) {
                my ( $year, $month, $day, $hour, $min, $sec ) = ( $1, $2, $3, $4, $5, $6 );
                my $offset;

                # hours may be over 23!!!
                if ( $hour >= 24 ) {

                    # correct this
                    $offset = 1;
                    $hour -= 24;
                } ## end if ( $hour >= 24 )

                my $start = localtime->strptime( "$year-$month-$day $hour:$min:$sec", "%Y-%m-%d %H:%M:%S" );

                $start += ONE_DAY if $offset;

                $event->{start} = $start->epoch;
            } ## end if ( $value =~ /^(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)$/)
            return;
        };
        /synopsis/i && do {
            $event->{synopsis} = $value;
            return;
        };
        /^parental$/i && do {
            $event->{parental_rating} = $value;
            return;
        };
        /^title$/i && do {
            $event->{title} = $value;
            return;
        };
        /^episode$/i && do {
            $event->{episode} = $value;
            return;
        };
        /duration/i && do {
            if ( $value =~ /(\d+)/ ) {
                $event->{duration} = $1;
            } else {
                $self->_error("Duration not valid number [$value]");
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

sub addEvent {
    my $self  = shift;
    my $event = $self->{currentEvent};

    # check if all event data is complete and valid
    my @missing;
    push( @missing, "start" )    unless defined $event->{start};
    push( @missing, "duration" ) unless defined $event->{duration} && $event->{duration} > 0;
    push( @missing, "title" )    unless defined $event->{title};
    if ( scalar @missing > 0 ) {
        $self->_error( "Missing or incorrect input data [" . join( ' ', @missing ) . "] line " . $self->{linecount} );
        return;
    }

    # language and codepage are defined elsewhere
    if ( $event->{episode} && $event->{episode} ne "" && $event->{episode} != 0 ) {
        $event->{subtitle} = "Epizoda " . $event->{episode};
    }

    # push to final array
    push( @{ $self->{eventList} }, $event );

    return 1;
} ## end sub addEvent

=head1 AUTHOR

This software is copyright (c) 2019 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
