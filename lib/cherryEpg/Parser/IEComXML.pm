package cherryEpg::Parser::IEComXML;
use 5.010;
use utf8;
use Moo;
use strictures 2;
use XML::Parser::PerlSAX;

extends 'cherryEpg::Parser';

our $VERSION = '0.28';

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

    my $handler = IEComXMLHandler->new();
    my $parser  = XML::Parser::PerlSAX->new(
        Handler => $handler,
        output  => $report
    );

    $parser->parse( Source => { SystemId => $self->{source} } );

    return $report;
} ## end sub parse

package IEComXMLHandler;
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
    $self->{report}{channel}   = $self->{Service};
} ## end sub end_document

sub start_element {
    my ( $self, $element ) = @_;

    if ( $element->{Name} eq "event" ) {
        $self->{currentEvent} = {};
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

    $self->{linecount} = $self->{_parser}->location()->{'LineNumber'};

SWITCH: for ( $element->{Name} ) {
        $_ eq "event" && do {

            # add the event to the list
            $self->addEvent();
            return;
        };
        $_ eq "start" && do {
            return if $value eq '';

            $event->{start} = localtime->strptime( $value, "%Y-%m-%dT%H:%M:%S" )->epoch;
            return;
        };
        $_ eq "length" && do {
            return if $value eq '';

            $event->{duration} = $value * 60;
            return;
        };
        /shortTitle/ && do {
            return if $value eq '';

            $event->{title} = $value;
            return;
        };
        /title/ && do {
            return if $value eq '';

            $event->{subtitle} = $value;
            return;
        };
        /description/ && do {
            return if $value eq '';

            $event->{description} = $value;
            return;
        };
        /summary/ && do {
            return if $value eq '';

            $event->{summary} = $value;
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
    push( @missing, "start" ) unless defined $event->{start};
    push( @missing, "title" ) unless defined $event->{title};

    if ( scalar @missing > 0 ) {
        $self->_error( "Missing or incorrect input data [" . join( ' ', @missing ) . "] line " . $self->{linecount} );
        return;
    }

    if ( exists $event->{summary} && $event->{summary} ne "" ) {
        $event->{synopsis} = $event->{summary};
        delete $event->{summary};
    }
    if ( exists $event->{description} && $event->{description} ne "" ) {
        if ( exists $event->{synopsis} ) {
            $event->{synopsis} .= "\n" . $event->{description};
        } else {
            $event->{synopsis} = $event->{description};
        }
        delete $event->{description};
    } ## end if ( exists $event->{description...})

    # push to final array
    push( @{ $self->{eventList} }, $event );

    return 1;
} ## end sub addEvent

=head1 AUTHOR

This software is copyright (c) 2020 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
