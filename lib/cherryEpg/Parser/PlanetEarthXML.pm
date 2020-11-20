package cherryEpg::Parser::PlanetEarthXML;
use 5.010;
use utf8;
use Moo;
use strictures 2;
use XML::Parser::PerlSAX;

extends 'cherryEpg::Parser';

our $VERSION = '0.25';

sub BUILD {
    my ( $self, $arg ) = @_;

    $self->{report}{parser} = __PACKAGE__;
}

=head3 parse( $parserOption)

Do the file processing and return a reference to hash with keys
- errorList => array with troubles during parsing
- eventList => hash of arrays of events found

=cut

sub parse {
    my ( $self, $option ) = @_;
    my $report = $self->{report};

    my $handler = PlanetEarthXMLHandler->new();
    my $parser  = XML::Parser::PerlSAX->new(
        Handler => $handler,
        output  => $report
    );

    $parser->parse( Source => { SystemId => $self->{source} } );

    return $report;
} ## end sub parse

package PlanetEarthXMLHandler;
use strict;
use warnings;
use Time::Piece;
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

    # this will be the list of events
    $self->{eventList} = [];

    # and the possible error list
    $self->{errorList} = [];
} ## end sub start_document

sub end_document {
    my ( $self, $element ) = @_;

    $self->{report}            = $self->{'_parser'}->{output};
    $self->{report}{eventList} = $self->{eventList};
    $self->{report}{errorList} = $self->{errorList};
} ## end sub end_document

sub start_element {
    my ( $self, $element ) = @_;

    if ( $element->{Name} =~ /programme/i ) {
        my $event;

        my $timeDate = $element->{Attributes}{date} . " " . $element->{Attributes}{time};

        # save the date and time Attributes
        if ( $timeDate =~ m/\d+\.\d+\.\d{4} \d+:\d+/ ) {
            $event->{start} = localtime->strptime( $timeDate, "%d.%m.%Y %H:%M" )->epoch;
        } else {
            $self->_error( "Incorrect date/time format [" . $timeDate . "] line " . $self->{linecount} );
        }

        $self->{currentEvent} = $event;
    } ## end if ( $element->{Name} ...)

    # store current language
    if ( $element->{Attributes}{lang} ) {
        $self->{currentLang} = $element->{Attributes}{lang};
    } else {
        $self->{currentLang} = '';
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
        /local_title|original_title/ && do {

            return if $value eq '';

            if ( $lang ne '' ) {
                $event->{lang}{$lang}{title} = $value;
            } else {
                $event->{title} = $value;
            }
            return;
        };
        /description/ && do {

            return if $value eq '';

            if ( $lang ne '' ) {
                $event->{lang}{$lang}{synopsis} = $value;
            } else {
                $event->{synopsis} = $value;
            }
            return;
        };
        /season_number/ && do {
            if ( $value and $value ne '' ) {
                $event->{subtitle} = $value + 0 . ". sezona";
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

    my $lang = 'sl';

    # default use slovene
    foreach my $key (qw( title synopsis )) {
        $event->{$key} = $event->{lang}{$lang}{$key} if exists $event->{lang}{$lang}{$key};
    }
    delete $event->{lang}{$lang};

    # try others
    foreach my $lang ( keys %{ $event->{lang} } ) {
        foreach my $key (qw( title synopsis )) {
            $event->{$key} = $event->{lang}{$lang}{$key} if exists $event->{lang}{$lang}{$key} && !exists $event->{$key};
        }
        delete $event->{lang}{$lang};
    } ## end foreach my $lang ( keys %{ ...})

    delete $event->{lang} if exists $event->{lang};

    return 1;
} ## end sub mapLang

sub addEvent {
    my $self  = shift;
    my $event = $self->{currentEvent};

    # check if all event data is complete and valid
    my @missing;
    push( @missing, "start" ) unless defined $event->{start};
    push( @missing, "title" ) unless defined $event->{title};

    if ( scalar @missing > 0 ) {
        $self->_error( "Missing or incorrect input data [" . join( ' ', @missing ) . "] line " . $self->{linecount} );
        return;
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
