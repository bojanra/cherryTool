package cherryEpg::Log4perlMyDBI;

use 5.024;
use base 'Log::Log4perl::Appender::DBI';

# I've added a few modifications to write level and category as numbers in the database.
#

our %_LEVEL_MAPPER = (
    'TRACE' => 0,
    'DEBUG' => 1,
    'INFO'  => 2,
    'WARN'  => 3,
    'ERROR' => 4,
    'FATAL' => 5
);

our %_CATEGORY_MAPPER = (
    'grabber'  => 0,
    'ingester' => 1,
    'builder'  => 2,
    'player'   => 3,
    'system'   => 4
);

sub calculate_bind_values {
    my ( $self, $p ) = @_;

    my @qmarks;
    my $user_ph_idx = 0;

    my $i = 0;

    if ( $self->{bind_value_layouts} ) {

        my $prev_pnum = 0;
        my $max_pnum  = 0;

        my @pnums = sort { $a <=> $b } keys %{ $self->{bind_value_layouts} };
        $max_pnum = $pnums[-1];

        #Convert text to number
        my $c                  = $p->{log4p_category};
        my $l                  = $p->{log4p_level};
        my $category_as_number = 0;
        my $level_as_number    = 0;
        $level_as_number    = $_LEVEL_MAPPER{$l}    if exists( $_LEVEL_MAPPER{$l} );
        $category_as_number = $_CATEGORY_MAPPER{$c} if exists( $_CATEGORY_MAPPER{$c} );

        #Walk through the integers for each possible bind value.
        #If it doesn't have a layout assigned from the config file
        #then shift it off the array from the $log call
        #This needs to be reworked now that we always get an arrayref? --kg 1/2003
        foreach my $pnum ( 1 .. $max_pnum ) {
            my $msg;

            #we've got a bind_value_layout to fill the spot
            if ( $self->{bind_value_layouts}{$pnum} ) {
                $msg = $self->{bind_value_layouts}{$pnum}
                    ->render( $p->{message}, $category_as_number, $level_as_number, 5 + $Log::Log4perl::caller_depth, );

                #we don't have a bind_value_layout, so get
                #a message bit
            } elsif ( ref $p->{message} eq 'ARRAY' && @{ $p->{message} } ) {

                #$msg = shift @{$p->{message}};
                $msg = $p->{message}->[ $i++ ];

                #here handle cases where we ran out of message bits
                #before we ran out of bind_value_layouts, just keep going
            } elsif ( ref $p->{message} eq 'ARRAY' ) {
                $msg = undef;
                $p->{message} = undef;

                #here handle cases where we didn't get an arrayref
                #log the message in the first placeholder and nothing in the rest
            } elsif ( !ref $p->{message} ) {
                $msg = $p->{message};
                $p->{message} = undef;

            }

            if ( $self->{MAX_COL_SIZE}
                && length($msg) > $self->{MAX_COL_SIZE} ) {
                substr( $msg, $self->{MAX_COL_SIZE} ) = '';
            }
            push @qmarks, $msg;
        } ## end foreach my $pnum ( 1 .. $max_pnum)
    } ## end if ( $self->{bind_value_layouts...})

    #handle leftovers
    if ( ref $p->{message} eq 'ARRAY' && @{ $p->{message} } ) {

        #push @qmarks, @{$p->{message}};
        push @qmarks, @{ $p->{message} }[ $i .. @{ $p->{message} } - 1 ];

    } ## end if ( ref $p->{message}...)

    return \@qmarks;
} ## end sub calculate_bind_values

=head1 AUTHOR

This software is copyright (c) 2019 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
