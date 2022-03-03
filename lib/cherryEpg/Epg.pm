package cherryEpg::Epg;

use 5.010;
use utf8;
use Moo;
use strictures 2;
use Try::Tiny;
use Carp;
use Encode;
use DBI qw(:sql_types);
use JSON::XS;
use POSIX qw(ceil);
use cherryEpg::EIT;
use IPC::SysV qw(SEM_UNDO S_IRWXU IPC_CREAT ftok);
use IPC::Semaphore qw(SEM_UNDO);

with( 'cherryEpg::Exporter', 'cherryEpg::Announcer' );

has config => (
    is  => 'ro',
    isa => sub {
        croak "must be a hash reference" unless ref $_[0] eq 'HASH';
    },
    required => 1
);

sub BUILD {
    my ( $self, $args ) = @_;

    # each segment is 3h
    # thus 24 segments => 3 days

    # initialize semaphore.
    my $token = ftok( $INC{"cherryEpg/Epg.pm"}, 1 );
    my $sem   = new IPC::Semaphore( $token, 1, S_IRWXU );

    unless ($sem) {

        # create if needed
        $sem = new IPC::Semaphore( $token, 1, S_IRWXU | IPC_CREAT );
        $sem->setval( 0, 1 );
    } ## end unless ($sem)

    $self->{sem} = $sem;

    return;
} ## end sub BUILD

=head3 dbh( )

Connect or reconnect to database and return handler.

=cut

sub dbh {
    my ($self) = @_;

    if ( $self->{_dbh}->{Active} and $self->{_dbh}->ping() ) {
        return $self->{_dbh};
    } else {
        $self->{_dbh} = try {
            DBI->connect(
                $self->config->{datasource},
                $self->config->{user},
                $self->config->{pass},
                {
                    AutoCommit        => 1,
                    RaiseError        => 1,
                    PrintError        => 0,
                    mysql_enable_utf8 => 1
                }
            );
        };
        return $self->{_dbh};
    } ## end else [ if ( $self->{_dbh}->{Active...})]
} ## end sub dbh

=head3 _lockdb()

Get lock on database. Wait until locked.

=cut

sub _lockdb {
    $_[0]->{sem}->op( 0, -1, SEM_UNDO );
}

=head3 _unlockdb()

Release lock on database.

=cut

sub _unlockdb {
    $_[0]->{sem}->op( 0, 1, SEM_UNDO );
}

=head3 dropTables( )

Drop all tables.

=cut

sub dropTables {
    my ($self) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;

    $self->_lockdb();
    $dbh->do('DROP TABLE IF EXISTS channel, eit, event, rule, section, version, log;');
    $self->_unlockdb();
} ## end sub dropTables

=head3 initdb( )

Initialize database with some basic table structure;

=cut

sub initdb {
    my ($self) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;

    $self->dropTables;

    $self->_lockdb();
    $dbh->do(
        "CREATE TABLE channel ( channel_id INTEGER,
                                     name VARCHAR(64),
                                     info BLOB,
                PRIMARY KEY( channel_id))
                ENGINE = MYISAM;"
    );

    $dbh->do(
        "CREATE TABLE event ( event_id INTEGER,
                                  channel_id INTEGER,
                                  start INTEGER UNSIGNED,
                                  stop INTEGER UNSIGNED,
                                  info BLOB,
                                  timestamp INTEGER UNSIGNED,
                PRIMARY KEY( channel_id, event_id))
                ENGINE = MYISAM;"
    );

    $dbh->do(
        "CREATE TABLE eit ( eit_id INTEGER,
                                pid INTEGER,
                                info BLOB,
                PRIMARY KEY( eit_id))
                ENGINE = MYISAM;"
    );

    $dbh->do(
        "CREATE TABLE rule ( eit_id INTEGER NOT NULL,
                                  service_id INTEGER,
                                  original_network_id INTEGER,
                                  transport_stream_id INTEGER,
                                  channel_id INTEGER NOT NULL,
                                  actual INTEGER,
                                  comment TEXT,
                PRIMARY KEY( eit_id, original_network_id, transport_stream_id, service_id))
                ENGINE = MYISAM;"
    );

    $dbh->do(
        "CREATE TABLE version ( service_id INTEGER,
                                    original_network_id INTEGER,
                                    transport_stream_id INTEGER,
                                    table_id INTEGER,
                                    version_number INTEGER,
                                    timestamp INTEGER UNSIGNED,
                PRIMARY KEY( service_id, original_network_id, transport_stream_id, table_id))
                ENGINE = MYISAM;"
    );

    $dbh->do(
        "CREATE TABLE section ( service_id INTEGER,
                                original_network_id INTEGER,
                                transport_stream_id INTEGER,
                                table_id INTEGER,
                                section_number INTEGER,
                                dump BLOB,
                PRIMARY KEY( service_id, original_network_id, transport_stream_id, table_id, section_number))
                ENGINE = MYISAM;"
    );

    $dbh->do(
        "CREATE TABLE log ( id INTEGER NOT NULL AUTO_INCREMENT,
                            timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                            level TINYINT,
                            category TINYINT,
                            text TEXT,
                            channel_id INTEGER,
                            eit_id INTEGER,
                            info MEDIUMBLOB,
                            PRIMARY KEY( id),
                            KEY c (category),
                            KEY l (level))
                            ENGINE = MYISAM;"
    );

    $dbh->do(
        "CREATE TRIGGER event_timestamp_insert BEFORE INSERT ON event
                FOR EACH ROW
                    SET NEW.timestamp = UNIX_TIMESTAMP();"
    );

    $dbh->do(
        "CREATE TRIGGER event_timestamp_update BEFORE UPDATE ON event
               FOR EACH ROW
                    SET NEW.timestamp = UNIX_TIMESTAMP();"
    );

    $dbh->do(
        "CREATE TRIGGER rule_delete AFTER DELETE ON rule
                FOR EACH ROW BEGIN
                    DELETE FROM version
                        WHERE version.service_id = old.service_id
                        AND version.original_network_id = old.original_network_id
                        AND version.transport_stream_id = old.transport_stream_id;
                    DELETE FROM section
                        WHERE section.service_id = old.service_id
                        AND section.original_network_id = old.original_network_id
                        AND section.transport_stream_id = old.transport_stream_id;
                END"
    );

    $dbh->do(
        "CREATE TRIGGER eit_delete BEFORE DELETE ON eit
                FOR EACH ROW BEGIN
                    DELETE FROM rule WHERE rule.eit_id = old.eit_id;
                    DELETE FROM log WHERE log.eit_id = old.eit_id;
                END"
    );

    $dbh->do(
        "CREATE TRIGGER channel_delete BEFORE DELETE ON channel
                FOR EACH ROW BEGIN
                    DELETE FROM event WHERE event.channel_id = old.channel_id;
                    DELETE FROM rule WHERE rule.channel_id = old.channel_id;
                    DELETE FROM log WHERE log.channel_id = old.channel_id;
                END"
    );
    $self->_unlockdb();

    return 1;
} ## end sub initdb

=head3 version ( )

Return database version.

=cut

sub version {
    my ($self) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;

    return ${ $self->dbh->selectrow_arrayref("SELECT version()") }[0];
} ## end sub version

=head3 healthCheck ( )

Run a healthcheck and return report.

=cut

sub healthCheck {
    my ($self) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;

    return $self->dbh->selectall_arrayref(
        "SELECT table_name,Engine,table_rows,Data_length,Create_time,Update_time,Check_time,table_collation FROM information_schema.tables WHERE table_schema = 'cherry_db'"
    );
} ## end sub healthCheck

=head3 reset ( )

Delete all records in section and version table
Next build will start from scratch.

Return 1 on success.

=cut

sub reset {
    my ($self) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;

    return $dbh->do("DELETE FROM section") && $dbh->do("DELETE FROM version");
} ## end sub reset

=head3 addChannel ( $channel_id, $name)
=head3 addChannel ( $hash)

Add or update channel referenced by $channel_id in channel table.

If channel with $channel_id exists the channel is updated, if not a
new is added.

The $channel_id is used as primary key.

$name is the channel name.

When the paramteres are passed as hash the whole hash is stored in database.

Return 1 on success.

=cut

sub addChannel {
    my ( $self, $arg, $name ) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;

    my $channel_id;

    if ( ref $arg eq "HASH" ) {
        $channel_id = $arg->{channel_id};
        $name       = $arg->{name};
    } else {
        $channel_id = $arg;
        $arg        = {};
    }

    # escape single quote
    $name =~ s/'/''/g;

    # assume latin2 as default destination codepage
    if ( !exists $arg->{codepage} ) {
        $arg->{codepage} = 'iso-8859-2';
    }

    my ($count) = $dbh->selectrow_array( "SELECT COUNT(*) FROM channel WHERE channel_id=?", undef, $channel_id );
    my $insertOrUpdate;

    # update existing or insert new
    if ( $count == 1 ) {
        $insertOrUpdate = $dbh->prepare("UPDATE channel SET info=?, name='$name' WHERE channel_id=$channel_id");
    } else {
        $insertOrUpdate = $dbh->prepare("INSERT INTO channel VALUES ( $channel_id, '$name', ?)");
    }
    return unless $insertOrUpdate;

    # bind blob
    $insertOrUpdate->bind_param( 1, encode_json($arg), SQL_BLOB );
    return $insertOrUpdate->execute();
} ## end sub addChannel

=head3 listChannel( $channel_id)

List channel or all if $channel_id not defined.
Return reference to an array of all hashed channel data.

=cut

sub listChannel {
    my ( $self, $channel_id ) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;

    my $list = $dbh->selectall_arrayref(
        "SELECT channel_id, name, info FROM channel WHERE 1"
            . ( defined $channel_id ? " AND channel_id=$channel_id" : "" )
            . " ORDER BY channel_id",
        { Slice => {} }
    );

    foreach my $channel (@$list) {
        my $compact = decode_json( $channel->{info} );
        $compact->{channel_id} = $channel->{channel_id};
        $compact->{name}       = $channel->{name};
        $channel               = $compact;
    } ## end foreach my $channel (@$list)

    return $list;
} ## end sub listChannel

=head3 listChannelLastUpdate( )

List all channels and last time they were updated.

Return array on success.

=cut

sub listChannelLastUpdate {
    my ($self) = @_;
    my $dbh = $self->dbh;
    return 0 unless $dbh;

    return $dbh->selectall_hashref(
        '(SELECT channel_id, timestamp from (SELECT DISTINCT channel_id, timestamp FROM event ORDER BY timestamp DESC) AS T GROUP BY channel_id)
        UNION ALL
        (SELECT channel_id, 0 FROM channel WHERE NOT EXISTS (SELECT DISTINCT channel_id FROM event WHERE channel.channel_id = event.channel_id) )',
        'channel_id'
    );
} ## end sub listChannelLastUpdate

=head3 listChannelEventCount ( $start, $stop)

Count number of events per interval for each channel.

Return array on success.

=cut

sub listChannelEventCount {
    my ( $self, $start, $stop ) = @_;
    my $dbh = $self->dbh;
    return 0 unless $dbh;

    my $last_midnight = int( time() / ( 24 * 60 * 60 ) ) * 24 * 60 * 60;

#    print "SELECT channel.name AS name, channel.channel_id AS channel_id, COUNT( event.channel_id) AS count FROM channel LEFT JOIN event ON channel.channel_id = event.channel_id WHERE event.start > " . ( $last_midnight + $start * 24 * 60 * 60 ) . " AND event.start < " . ( $last_midnight + $stop * 24 * 60 * 60 ) . " GROUP BY event.channel_id UNION ALL SELECT channel.name, channel.channel_id, 0 FROM channel WHERE NOT EXISTS (SELECT event.channel_id FROM event WHERE channel.channel_id = event.channel_id AND event.start > " . ( $last_midnight + $start * 24 * 60 * 60 ) . " AND event.start < " . ( $last_midnight + $stop * 24 * 60 * 60 ) . ") ORDER BY channel_id","\n";
    return $dbh->selectall_arrayref(
        "SELECT channel.name AS name, channel.channel_id AS channel_id, COUNT( event.channel_id) AS count
	    FROM channel LEFT JOIN event ON channel.channel_id = event.channel_id WHERE
	        event.start >= " . ( $last_midnight + $start * 24 * 60 * 60 ) . " AND
	        event.start < " .  ( $last_midnight + $stop * 24 * 60 * 60 ) . " GROUP BY event.channel_id
	    UNION ALL
	    SELECT channel.name, channel.channel_id, 0 FROM channel WHERE NOT EXISTS
	    (SELECT event.channel_id FROM event WHERE
	        channel.channel_id = event.channel_id AND
	        event.start >= " . ( $last_midnight + $start * 24 * 60 * 60 ) . " AND
	        event.start < " .  ( $last_midnight + $stop * 24 * 60 * 60 ) . ") ORDER BY channel_id"
    );
} ## end sub listChannelEventCount


=head3 deleteChannel( $channel_id)

Delete channel with $channel_id.

Remove all channels, if $channel_id not defined.

All events of the according channel are automatically removed.

Return 1 on success.

=cut

sub deleteChannel {
    my ( $self, $channel_id ) = @_;
    my $dbh = $self->dbh;
    return 0 unless $dbh;

    return $dbh->do( "DELETE FROM channel WHERE 1" . ( defined $channel_id ? " AND channel_id=$channel_id" : "" ) );
} ## end sub deleteChannel

=head3 addEvent( $event)

Add an $event to event table.
$event must be reference to hash containing at least
fields: $event->{start}, $event->{stop}, $event->{channel_id}

start, stop MUST be in EPOCH

Optional fields are:
$event->{id}, $event->{running_status}, $event->{free_CA_mode}
and $event->{descriptors}

Return event_key of inserted row.

REGARDING CODEPAGE USAGE AND STORING.
String data must be UTF-8 encoded. During the storage process it is interpreted as utf-8.
The module is converting to final codepage before packing in sections.

=cut

sub addEvent {
    my ( $self, $event ) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;

    if (   !exists $event->{channel_id}
        or !exists $event->{stop}
        or !exists $event->{start}
        or $event->{stop} <= $event->{start}
        or $dbh->selectrow_array( "SELECT COUNT(*) FROM channel WHERE channel_id = ?", undef, $event->{channel_id} ) == 0 ) {
        return;
    } ## end if ( !exists $event->{...})

    $event->{duration} = $event->{stop} - $event->{start};
    $event->{running_status} =
        exists $event->{running_status} ? $event->{running_status} & 1 : 0;
    $event->{free_CA_mode} =
        exists $event->{free_CA_mode} ? $event->{free_CA_mode} & 1 : 0;

    # in case when no event_id is defined
    if ( !defined $event->{id} ) {

        # find highest event_id currently used
        my @row = $dbh->selectrow_array(
            "SELECT event_id FROM event WHERE channel_id = ?
            ORDER BY event_id DESC LIMIT 1", undef, $event->{channel_id}
        );

        my $last_event_id;

        # check if query returned result
        if ( $#row == 0 ) {
            $last_event_id = $row[0];
            if ( $last_event_id >= 0xffff ) {

                # check step by step if index from 0 on are in use
                my $num = $dbh->prepare(
                    "SELECT event_id FROM event WHERE
                    channel_id = '$event->{channel_id}' ORDER BY event_id"
                );
                $num->execute();
                my $lastused = -1;
                my $result;
                while ( $result = $num->fetch() ) {
                    if ( ${$result}[0] - $lastused > 1 ) {
                        $last_event_id = $lastused + 1;
                        last;
                    }
                    $lastused = ${$result}[0];
                } ## end while ( $result = $num->fetch...)
            } else {

                # and increment by 1
                ++$last_event_id;
            }
        } else {

            # there is no result, no events exist
            $last_event_id = 0;
        }
        $event->{id} = $last_event_id;
    } ## end if ( !defined $event->...)

    # limit to 16 bit (integer)
    $event->{id} &= 0xffff;

    # prepare the insertation
    my $insert = $dbh->prepare(
        "REPLACE INTO event VALUES ( $event->{id}, $event->{channel_id},
            $event->{start}, $event->{stop}, ?, NULL)"
    );
    return unless $insert;

    # bind blob and insert event
    $insert->bind_param( 1, encode_json($event), SQL_BLOB );
    if ( $insert->execute() ) {
        return $event->{id};
    } else {
        return;
    }
} ## end sub addEvent

=head3 listEvent( $channel_id, $event_id, $start, $stop, $touch)

List events with $channel_id in cronological order.

$event_id, $start, $stop, $touch are optional parameters.
$event_id is used as selection filter.
$start, $stop are used as interval specification.
If $touch is defined only elements with timestamp newer than
$touch are returned.

Return array of events.

=cut

sub listEvent {
    my ( $self, $channel_id, $event_id, $start, $stop, $touch ) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;

    return unless defined $channel_id;

    my $sel = $dbh->prepare(
        "SELECT event_id, channel_id, start,
        stop, info, timestamp FROM event
        WHERE channel_id=$channel_id "
            . ( defined $event_id ? " AND event_id = $event_id" : "" )
            . ( defined $start    ? " AND start >= $start"      : "" )
            . ( defined $stop     ? " AND stop >= $stop"        : "" )
            . ( defined $touch    ? " AND timestamp > $touch"   : "" )
            . " ORDER BY start"
    );
    $sel->execute();

    my ( $_event_id, $_channel_id, $_start, $_stop, $_info, $_timestamp );
    $sel->bind_columns( \( $_event_id, $_channel_id, $_start, $_stop, $_info, $_timestamp ) );

    my @list;

    while ( $sel->fetch ) {
        my $data = decode_json($_info);
        $data->{event_id}   = $_event_id;
        $data->{channel_id} = $_channel_id;
        $data->{start}      = $_start;
        $data->{stop}       = $_stop;
        $data->{timestamp}  = $_timestamp;
        push( @list, $data );
    } ## end while ( $sel->fetch )
    return @list;
} ## end sub listEvent

=head3 deleteEvent( $channel_id, $event_id, $start_min, $start_max, $stop_min, $stop_max)

Delete events with $channel_id.

$event_id, $stop_min, $stop_max, $start_min and $start_max are optional parameters.
$channel_id and $event_id are used as selection filter.

Delete events that have start in between $start_min, $start_max and stop in between
$stop_min, $stop_max. Use only defined markers.

Return number of deleted events.

=cut

sub deleteEvent {
    my ( $self, $channel_id, $event_id, $start_min, $start_max, $stop_min, $stop_max ) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;

    my $ret =
        $dbh->do( "DELETE FROM event WHERE 1"
            . ( defined $channel_id ? " AND channel_id=$channel_id" : "" )
            . ( defined $event_id   ? " AND event_id=$event_id"     : "" )
            . ( defined $start_min  ? " AND start >= $start_min"    : "" )
            . ( defined $start_max  ? " AND start  < $start_max"    : "" )
            . ( defined $stop_min   ? " AND stop  > $stop_min"      : "" )
            . ( defined $stop_max   ? " AND stop <= $stop_max"      : "" ) );
    return $ret eq "0E0" ? 0 : $ret;
} ## end sub deleteEvent

=head3 addRule( $eit_id, $service_id, $original_network_id, $transport_stream_id,
                $channel_id, $actual, $comment)

Add eit generator rule.
All parameters must be defined.

Attention before adding rules eit and channel must be defined!

Return 1 on success.

=cut

sub addRule {
    my ( $self, $eit_id, $service_id, $original_network_id, $transport_stream_id, $channel_id, $actual, $comment ) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;

    if ( ref $eit_id eq "HASH" ) {
        $service_id          = $eit_id->{service_id};
        $original_network_id = $eit_id->{original_network_id};
        $transport_stream_id = $eit_id->{transport_stream_id};
        $channel_id          = $eit_id->{channel_id};
        $actual              = $eit_id->{actual};
        $comment             = exists $eit_id->{comment} ? $eit_id->{comment} : "";
        $eit_id              = $eit_id->{eit_id};
    } ## end if ( ref $eit_id eq "HASH")

    if (   !defined $eit_id
        or !defined $service_id
        or !defined $original_network_id
        or !defined $transport_stream_id
        or !defined $channel_id
        or !defined $actual ) {
        return;
    } ## end if ( !defined $eit_id ...)

    $comment //= "";

    return $dbh->do(
        "REPLACE INTO rule VALUES
        ((SELECT eit_id FROM eit WHERE eit_id = $eit_id),
        $service_id, $original_network_id, $transport_stream_id,
        (SELECT channel_id FROM channel WHERE channel_id = $channel_id), $actual, '$comment')"
    );
} ## end sub addRule

=head3 listRule( $eit_id)

List eit generator rules filtered by eit_id or all if no id defined.

Return reference to an array of hash of rules.

=cut

sub listRule {
    my ( $self, $eit_id ) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;

    return $dbh->selectall_arrayref(
        "SELECT * FROM rule WHERE 1" . ( defined $eit_id ? " AND eit_id=$eit_id" : "" ) . " ORDER BY eit_id, channel_id",
        { Slice => {} } );
} ## end sub listRule

=head3 deleteRule( $eit_id, $service_id, $original_network_id, $transport_stream_id)

Delete eit generator rule.
Parameters are optional.

Return number of deleted rules.

=cut

sub deleteRule {
    my ( $self, $eit_id, $service_id, $original_network_id, $transport_stream_id ) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;

    my $ret =
        $dbh->do( "DELETE FROM rule WHERE 1"
            . ( defined $eit_id              ? " AND eit_id=$eit_id"                           : "" )
            . ( defined $service_id          ? " AND service_id=$service_id"                   : "" )
            . ( defined $original_network_id ? " AND original_network_id=$original_network_id" : "" )
            . ( defined $transport_stream_id ? " AND transport_stream_id=$transport_stream_id" : "" ) );
    return $ret eq "0E0" ? 0 : $ret;
} ## end sub deleteRule

=head3 addEit( $eit_id, $pid)
=head3 addEit( $hash)

Add output EIT definition wit $eit_id. The default $pid number is 18.
When the paramteres are passed as hash the whole hash is stored in database.

Return 1 on success.

=cut

sub addEit {
    my ( $self, $arg, $pid ) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;

    $pid //= 18;
    my $eit_id;

    if ( ref $arg eq "HASH" ) {
        $eit_id = $arg->{eit_id};
        $pid    = exists $arg->{pid} ? $arg->{pid} : 18;
    } else {
        $eit_id = $arg;
        $arg    = {};
    }

    my $insert = $dbh->prepare("REPLACE INTO eit VALUES ( $eit_id, $pid, ?)");

    return unless $insert;

    # bind blob
    $insert->bind_param( 1, encode_json($arg), SQL_BLOB );
    return $insert->execute();
} ## end sub addEit

=head3 listEit( $eit_id)

List destination with $eit_id or all if not defined in table eit.
Return reference to an array of all hashed target eit data.

=cut

sub listEit {
    my ( $self, $eit_id ) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;

    my $list = $dbh->selectall_arrayref(
        "SELECT eit_id, pid, info FROM eit WHERE 1" . ( defined $eit_id ? " AND eit_id=$eit_id" : "" ) . " ORDER BY eit_id",
        { Slice => {} } );

    foreach my $eit (@$list) {
        my $compact = decode_json( $eit->{info} );
        $compact->{pid}    = $eit->{pid};
        $compact->{eit_id} = $eit->{eit_id};
        $eit               = $compact;
    } ## end foreach my $eit (@$list)
    return $list;
} ## end sub listEit

=head3 deleteEit( $eit_id)

Delete EIT with $eit_id.
Remove all destinations, if $eit_id not defined.
All rules with destination $eit_id are automatically removed.

Return 1 on success.

=cut

sub deleteEit {
    my ( $self, $eit_id ) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;

    return $dbh->do( "DELETE FROM eit WHERE 1" . ( defined $eit_id ? " AND eit_id=$eit_id" : "" ) );
} ## end sub deleteEit

=head3 updateEit( $eit_id)

Use rules for updateing Eit sections of given $eit_id in database.

Return 1 on success.
Return 0 if sections are already uptodate.
Return undef on error;

=cut

sub updateEit {
    my ( $self, $eit_id ) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;

    my $updated = 0;

    if ( !defined $eit_id ) {
        return;
    }

    my $sel = $dbh->prepare(
        "SELECT rule.*, channel.info FROM rule JOIN channel WHERE eit_id=$eit_id AND rule.channel_id = channel.channel_id ORDER BY RAND()"
    );
    $sel->execute();

    # always use this time in queries
    my $currentTime = time();

    my $ret;
    my $rule;
    while ( $rule = $sel->fetchrow_hashref ) {

        # join all rule/channel info in a single hash
        my $info = decode_json( $rule->{info} );
        delete $rule->{info};
        @{$rule}{ keys %$info } = values %$info;

        # first calculate present/following
        $ret = $self->updateEitPresent( $rule, $currentTime );
        if ( !defined $ret ) {
            return;
        }
        $updated |= $ret;

        # and then calculate schedule
        if ( exists $rule->{maxsegments} and $rule->{maxsegments} > 0 ) {
            $ret = $self->updateEitSchedule( $rule, $currentTime );
            if ( !defined $ret ) {
                return;
            }
            $updated |= $ret;
        } ## end if ( exists $rule->{maxsegments...})
    } ## end while ( $rule = $sel->fetchrow_hashref)
    return $updated;
} ## end sub updateEit

=head3 updateEitPresent( $rule)

Update eit sections for given $rule.
$rule is reference to hash containing keys:
eit_id, service_id, original_network_id, transport_stream_id, service_id, actual

Update sections only if there are changes in event table of schedule since last update.

Return undef if failed.
Return 0 if sections are already uptodate.
Return 1 after updating sections.

=cut

sub updateEitPresent {
    my ( $self, $rule, $currentTime ) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;

    # extend the $rule information
    $rule->{table_id} = $rule->{actual} == 1 ? 0x4e : 0x4f;

    my $present_following = cherryEpg::EIT->new( rule => $rule );

    # lookup version_number used at last generation of eit and timestamp
    my $select = $dbh->prepare(
        "SELECT version_number, timestamp FROM version
        WHERE service_id=$rule->{service_id} AND original_network_id=$rule->{original_network_id}
        AND transport_stream_id=$rule->{transport_stream_id} AND table_id=$rule->{table_id}"
    );
    $select->execute();

    my ( $last_version_number, $last_update_timestamp ) = $select->fetchrow_array();

    # if lookup wasn't succesfull we need to update the eit anyway
    if ( !defined $last_version_number ) {
        $last_update_timestamp = 0;
        $last_version_number   = 0;
    }

    # find last started event
    $select = $dbh->prepare(
        "SELECT event_id, start, stop,
        info, timestamp FROM event
        WHERE channel_id=$rule->{channel_id} AND start <= $currentTime
        ORDER BY start DESC LIMIT 1"
    );
    $select->execute();

    my $last_started_event = $select->fetchrow_hashref;

    # find following event
    $select = $dbh->prepare(
        "SELECT event_id, start, stop,
        info, timestamp FROM event
        WHERE channel_id=$rule->{channel_id} AND start > $currentTime
        ORDER BY start LIMIT 1"
    );
    $select->execute();

    my $following_event = $select->fetchrow_hashref;

    my $buildEit = 0;

    # check if we need an update
    # is the last started event still lasting
    if ( defined $last_started_event && $last_started_event->{stop} > $currentTime ) {

        # was the start already published or is there a change in the event data
        if (
            $last_started_event->{start} > $last_update_timestamp
            ||    # present event started after last update of eit
            $last_started_event->{timestamp} > $last_update_timestamp
            ||    # present event was modified since last update of eit
            defined $following_event && $following_event->{timestamp} > $last_update_timestamp
           )      # following event was modified since last update of eit
        {
            $buildEit = 1;
        } ## end if ( $last_started_event...)
    } else {

        # last event is over - there is a gap now
        # was the end of the last event published or is there a change in event data of following event
        if (
            defined $last_started_event && $last_started_event->{stop} > $last_update_timestamp
            ||    # end of last started event was not pulished
            defined $following_event && $following_event->{timestamp} > $last_update_timestamp
           )      # followig event was modified
        {
            $buildEit = 1;
        } ## end if ( defined $last_started_event...)
    } ## end else [ if ( defined $last_started_event...)]

    return 0 unless $buildEit;

    my $pevent;

    # if there is a current event add it to table
    # or add an empty section
    if ( defined $last_started_event && $last_started_event->{stop} > $currentTime ) {
        $pevent = _unfreezeEvent($last_started_event);
        $pevent->{running_status} = 4;
    }
    $self->announcerInsert( 0, $pevent );
    $present_following->add2Section( 0, $pevent );

    # if there is a following event add it to table
    my $fevent;
    if ( defined $following_event ) {
        $fevent = _unfreezeEvent($following_event);
        $fevent->{running_status} = ( $following_event->{start} - $currentTime ) < 20 ? 2 : 1;
    }
    $self->announcerInsert( 1, $fevent );
    $present_following->add2Section( 1, $fevent );

    #
    # Add this to playout and update version
    ++$last_version_number;

    # Prepare the new sections
    my $sections = $present_following->getSections($last_version_number);

    $self->_lockdb();

    # Remove all section of this table
    $dbh->do(
        "DELETE FROM section WHERE service_id=$rule->{service_id}
              AND original_network_id=$rule->{original_network_id}
              AND transport_stream_id=$rule->{transport_stream_id}
              AND table_id=$rule->{table_id}"
    );

    my $insert = $dbh->prepare(
        "INSERT INTO section VALUES ( $rule->{service_id},
        $rule->{original_network_id}, $rule->{transport_stream_id}, $rule->{table_id}, ?, ?)"
    );

    foreach my $section_number ( keys %$sections ) {
        $insert->bind_param( 1, $section_number );
        $insert->bind_param( 2, $sections->{$section_number}, SQL_BLOB );
        $insert->execute();
    }

    $dbh->do(
        "REPLACE INTO version VALUES ( $rule->{service_id},
        $rule->{original_network_id}, $rule->{transport_stream_id}, $rule->{table_id},
        $last_version_number, $currentTime)"
    );
    $self->_unlockdb();

    return 1;
} ## end sub updateEitPresent

=head3 updateEitSchedule( $rule)

Update eit playout packet for given $rule.
$rule is reference to hash containing keys:
eit_id, service_id, original_network_id, transport_stream_id, service_id, actual, maxsegments

Update sections only if there are changes in event table of schedule since last update.

=cut

sub updateEitSchedule {
    my ( $self, $rule, $currentTime ) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;

    my $num_subtable = int( ( $rule->{maxsegments} - 1 ) / 32 );

    my $last_midnight = int( $currentTime / ( 24 * 60 * 60 ) ) * 24 * 60 * 60;

    # iterate over all subtables
    my $subtable_count = 0;
    while ( $subtable_count <= $num_subtable ) {

        # correct the $rule information
        $rule->{table_id} = ( $rule->{actual} == 1 ? 0x50 : 0x60 ) + $subtable_count;

        my $schedule = cherryEpg::EIT->new( rule => $rule );

        # lookup version_number used at last generation of eit and timestamp
        my $select = $dbh->prepare(
            "SELECT version_number, timestamp FROM version
            WHERE service_id=$rule->{service_id} AND original_network_id=$rule->{original_network_id}
            AND transport_stream_id=$rule->{transport_stream_id} AND table_id=$rule->{table_id}"
        );

        $select->execute();
        my ( $last_version_number, $last_update_timestamp ) = $select->fetchrow_array();

        # if lookup wasn't succesfull we need to update the eit anyway
        if ( !defined $last_version_number ) {
            $last_update_timestamp = 0;
            $last_version_number   = 0;
        }

        # first segment number in this subtable
        my $first_segment = $subtable_count * 32;

        # start of subtable interval
        my $subtable_start = $last_midnight + $first_segment * 3 * 60 * 60;

        # last segment in this subtable (actually it is the next of the last)
        my $last_segment =
              $rule->{maxsegments} >= $first_segment + 32
            ? $first_segment + 32
            : $rule->{maxsegments};

        # end of subtable interval and maxsegments
        my $subtable_stop = $last_midnight + $last_segment * 3 * 60 * 60;

        # find last modification time of events in this subtable
        $select = $dbh->prepare(
            "SELECT timestamp FROM event
            WHERE channel_id=$rule->{channel_id}
            AND start >= $subtable_start
            AND start < $subtable_stop
            ORDER BY timestamp DESC LIMIT 1"
        );
        $select->execute();

        my ($last_event_modification) = $select->fetchrow_array() || 0;

        # has there any event stopped since last update
        # if yes this event can be removed from schedule
        my ($n) = $dbh->selectrow_array(
            "SELECT count(*) FROM event
            WHERE channel_id=$rule->{channel_id}
            AND stop > $last_update_timestamp
            AND stop < $currentTime"
        );

        # skip this subtable if there is no need for updating
        next
            if $last_update_timestamp >= $last_midnight
            and $last_event_modification <= $last_update_timestamp
            and $n == 0;

        # iterate over each segment
        my $segment_count = $first_segment;
        while ( $segment_count < $last_segment ) {

            # segment start is in future
            if ( $last_midnight + $segment_count * 3 * 60 * 60 >= $currentTime ) {
                $select = $dbh->prepare(
                    "SELECT event_id, start,
                    stop, info, timestamp FROM event
                    WHERE channel_id=$rule->{channel_id}
                    AND start >= " . ( $last_midnight + $segment_count * 3 * 60 * 60 ) . "
                    AND start < " .  ( $last_midnight + ( $segment_count + 1 ) * 3 * 60 * 60 ) . " ORDER BY start"
                );
                $select->execute();

                my $event;
                while ( $event = $select->fetchrow_hashref ) {
                    my $ue = _unfreezeEvent($event);
                    $ue->{running_status} = 1;
                    $schedule->add2Segment( $segment_count, $ue );
                }
            } ## end if ( $last_midnight + ...)

            # segment stop is in past
            elsif ( $last_midnight + ( $segment_count + 1 ) * 3 * 60 * 60 - 1 < $currentTime ) {

                # add empty segment
                $schedule->add2Section( ( $segment_count % 32 ) * 8 );
            }

            # segment start is in past but segment end is in future
            else {
                $select = $dbh->prepare(
                    "SELECT event_id, start, stop,
                    info, timestamp FROM event
                    WHERE channel_id=$rule->{channel_id}
                    AND stop >= $currentTime
                    AND start < " . ( $last_midnight + ( $segment_count + 1 ) * 3 * 60 * 60 ) . "
                    ORDER BY start"
                );
                $select->execute();

                my $event;
                while ( $event = $select->fetchrow_hashref ) {
                    my $ue = _unfreezeEvent($event);
                    $ue->{running_status} = $event->{start} < $currentTime ? 4 : 1;
                    $schedule->add2Segment( $segment_count, $ue );
                }
            } ## end else [ if ( $last_midnight + ...)]
            ++$segment_count;
        } ## end while ( $segment_count < ...)

        # Add subtable to playout and update version
        ++$last_version_number;

        # Prepare the new sections
        my $sections = $schedule->getSections($last_version_number);

        $self->_lockdb();

        # Remove all section of this table
        $dbh->do(
            "DELETE FROM section WHERE
            service_id=$rule->{service_id} AND original_network_id=$rule->{original_network_id}
            AND transport_stream_id=$rule->{transport_stream_id} AND table_id=$rule->{table_id}"
        );

        my $insert = $dbh->prepare(
            "INSERT INTO section VALUES ( $rule->{service_id},
            $rule->{original_network_id}, $rule->{transport_stream_id}, $rule->{table_id}, ?, ?)"
        );

        # return unless $insert;

        foreach my $section_number ( keys %$sections ) {
            $insert->bind_param( 1, $section_number );
            $insert->bind_param( 2, $sections->{$section_number}, SQL_BLOB );
            $insert->execute();
        }

        $dbh->do(
            "REPLACE INTO version VALUES ( $rule->{service_id},
            $rule->{original_network_id}, $rule->{transport_stream_id}, $rule->{table_id},
            $last_version_number, $currentTime)"
        );

        $self->_unlockdb();
    } continue {
        ++$subtable_count;
    }
    return 0;
} ## end sub updateEitSchedule

=head3 getEit( $eit_id, $timeFrame)

Build final EIT from all sections in table for given $eit_id and $timeFrame.

Return the complete TS chunk to be played within the timeframe.
Return undef on error.

=cut

sub getEit {
    my ( $self, $eit_id, $timeFrame ) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;
    return unless defined $eit_id;

    $timeFrame //= 30;    # this is the time frame for which we are building the fragment of the TS
    my $pid;

    # get the pid number of the destination chunk
    $pid = $dbh->selectrow_array( "SELECT pid FROM eit WHERE eit_id=$eit_id", undef );

    return unless $pid;

    my $eit = shift( @{ $self->listEit($eit_id) } );

    # fetch all sections from database
    my $sel = $dbh->prepare(
        "SELECT table_id, section.service_id, section_number, dump FROM section JOIN rule ON (
        section.service_id = rule.service_id AND section.original_network_id = rule.original_network_id
        AND section.transport_stream_id = rule.transport_stream_id ) WHERE rule.eit_id = $eit_id AND
        ((rule.actual = 1 AND (section.table_id = 78 OR section.table_id & 240 = 80)) OR
        (rule.actual = 0 AND (section.table_id = 79 OR section.table_id & 240 = 96))) ORDER BY RAND()"
    );
    $sel->execute();

    my ( $_table_id, $_service_id, $_section_number, $_dump );
    $sel->bind_columns( \( $_table_id, $_service_id, $_section_number, $_dump ) );

    my %pfSections = (
        present   => { packetCount => 0, mts => '' },
        following => { packetCount => 0, mts => '' }
    );
    my $pfFrequency = ceil( $timeFrame / 1.7 );    # DON'T CHANGE THIS, IT IS THE BASIC CYCLE
                                                   # the repetition period must be at least 2s by

    my @otherSections;
    my $allPacketCount = 0;
    my $lastOccur      = {};

    # convert section into MPEG transport stream package and store in hash with
    # some basic information for building up the final MTS
    # the sections are grouped by present, following and other
    while ( $sel->fetch ) {
        my $section;
        $section->{mts}            = $_dump;
        $section->{size}           = length($_dump) / 188;
        $section->{frequency}      = $self->getSectionFrequency( $_table_id, $_section_number, $timeFrame );
        $section->{table_id}       = $_table_id;
        $section->{service_id}     = $_service_id;
        $section->{section_number} = $_section_number;

        # skip schedule tables for other service if "SEMIMESH" option set
        next if ( $_table_id & 240 ) == 96 and $eit->{option}{SEMIMESH} and $eit->{option}{SEMIMESH} == 1;

        # p/f table have a higher repetition rate (every 2s) and therefore are grouped separate
        if ( $_table_id == 0x4e || $_table_id == 0x4f ) {
            $section->{frequency} = $pfFrequency;
            if ( $_section_number == 0 ) {
                $pfSections{present}{packetCount} += $section->{size};
                $pfSections{present}{mts} .= $section->{mts};
            } else {
                $pfSections{following}{packetCount} += $section->{size};
                $pfSections{following}{mts} .= $section->{mts};
            }
        } else {
            push( @otherSections, $section );
        }
        $allPacketCount += $section->{frequency} * $section->{size};
    } ## end while ( $sel->fetch )

    # minimum number of packets between sections with same table_id/service_id
    my $minPacketGap = ceil( $allPacketCount / ( $timeFrame * 40 ) );

    # calculate available space for other sections than present following
    my $nettoSpace = $allPacketCount - $pfFrequency * ( $pfSections{present}{packetCount} + $pfSections{following}{packetCount} );

    # we are going to put the sections as following
    # PRESENT other FOLLOWING other PRESENT other FOLLOWING other ....
    # therefore we have 2 x $pfFrequency gaps to fill up with other sections
    my $interPfGap = ceil( $nettoSpace / ( 2 * $pfFrequency ) );

    # it is intentionally decimal number, if there are a small number of sections

    # based on nettoSpace we can calculate the
    # specifical spacing between each repetition of a section
    foreach my $section (@otherSections) {
        $section->{spacing} = int( $nettoSpace / $section->{frequency} + .5 ) - $section->{size} - 1;

        # this will be used to count down, when the next repetition should occur
        $section->{nextApply} = 0;

        # has the section already been played
        $section->{played} = 0;

        # last occurence position of section with same table_id and service_id
        if ( exists $lastOccur->{ $section->{table_id} }{ $section->{service_id} } ) {
            $section->{last} = \$lastOccur->{ $section->{table_id} }{ $section->{service_id} };
        } else {
            $lastOccur->{ $section->{table_id} }{ $section->{service_id} } = -1;
            $section->{last} = \$lastOccur->{ $section->{table_id} }{ $section->{service_id} };
        }

#        printf( " sid: %2i table: %4i spacing: %3i freq: %4i\n", $section->{service_id}, $section->{table_id}, $section->{spacing}, $section->{frequency});
    } ## end foreach my $section (@otherSections)

#    printf( " all: %4i netto: %4i gap: %4i mingap: %4i rest: %4i\n", $allPacketCount, $nettoSpace, $interPfGap, $minPacketGap, $nettoSpace-$pfFrequency*$interPfGap);

    # let's build the stream
    my $pfCount             = 2 * $pfFrequency;
    my $finalMts            = '';
    my $finalMtsPacketCount = 0;
    my $gapSpace            = 0;
    while ( $pfCount > 0 ) {

        # put alternating present and following mts in the stream
        if ( $pfCount % 2 == 0 ) {
            $finalMts .= $pfSections{present}{mts};
            $finalMtsPacketCount += $pfSections{present}{packetCount};
        } else {
            $finalMts .= $pfSections{following}{mts};
            $finalMtsPacketCount += $pfSections{following}{packetCount};
        }

        $pfCount -= 1;

        # now fill up the gap with other section
        $gapSpace += $interPfGap;

        # at last iteration we need to put all remaining packets in the stream
        if ( $pfCount == 0 ) {
            $gapSpace = $allPacketCount - $finalMtsPacketCount;
        }

        my $sectionCount                  = 0;
        my $numInsertedPacketsInIteration = 0;

        # allow initial sorting of sections
        my $j = -1;

#        printf( " filling j: %3i gapspace: %3i pfcount: %2i sum: %3i all: %3i #sections: %3i\n", $j, $gapSpace, $pfCount, $finalMtsPacketCount, $allPacketCount, $#otherSections);
        while ( $gapSpace > 0 && $finalMtsPacketCount < $allPacketCount && scalar @otherSections > 0 ) {

            # sort only at the begin and if we have inserted all packed once
            if ( $j == -1 || $j > $#otherSections ) {

                # correct counters for sections just before sort - optimization
                if ($numInsertedPacketsInIteration) {
                    foreach my $section (@otherSections) {
                        $section->{nextApply} -= $numInsertedPacketsInIteration if $section->{played};
                    }
                    $numInsertedPacketsInIteration = 0;
                } ## end if ($numInsertedPacketsInIteration)

                # sort sections by number when it has to apply, frequency and size
                @otherSections = sort {
                           $a->{nextApply} <=> $b->{nextApply}
                        || $b->{frequency} <=> $a->{frequency}
                        || ${ $a->{last} } <=> ${ $b->{last} }
                } @otherSections;
                $j = 0;
            } ## end if ( $j == -1 || $j > ...)

            my $border = $finalMtsPacketCount - 2 * $minPacketGap;
            $border = 0 if $border < 0;

            while ( $j < $#otherSections && ${ $otherSections[$j]->{last} } > $border ) {
                $j = $j + 1;
            }

            $sectionCount += 1;
            my $numInsertedPackets = $otherSections[$j]->{size};

            $gapSpace -= $numInsertedPackets;

            # add sections to output
            $finalMts .= $otherSections[$j]->{mts};

            $otherSections[$j]->{frequency} -= 1;
            $otherSections[$j]->{nextApply} = $otherSections[$j]->{spacing} + $numInsertedPacketsInIteration;
            $otherSections[$j]->{played}    = 1;
            $finalMtsPacketCount += $numInsertedPackets;
            ${ $otherSections[$j]->{last} } = $finalMtsPacketCount;

#            printf( " j: %3i size: %2i gapspace: %3i pfcount: %2i sum: %3i all: %3i\n", $j, $otherSections[$j]->{size}, $gapSpace, $pfCount, $finalMtsPacketCount, $allPacketCount);

            # if all repetitions have been done, remove section from pool
            if ( $otherSections[$j]->{frequency} == 0 ) {

#                printf( " played: %3i section_id: %3i service_id: %3i\n", $otherSections[$j]->{played}, $otherSections[$j]->{section_number}, $otherSections[$j]->{service_id});
                splice( @otherSections, $j, 1 );    # remove finished sections
            }

            # sum up all inserted packets before next sort
            $numInsertedPacketsInIteration += $numInsertedPackets;

            $j += 1;

        } ## end while ( $gapSpace > 0 && ...)
    } ## end while ( $pfCount > 0 )

    # correct continuity counter
    my $continuity_counter = 0;
    for ( my $j = 0 ; $j < length($finalMts) ; $j += 188 ) {
        vec( $finalMts, $j + 3, 8 ) = 0x10 | ( $continuity_counter & 0x0f );
        $continuity_counter += 1;
        vec( $finalMts, $j + 1, 8 ) = ( vec( $finalMts, $j + 1, 8 ) & 0xe0 ) | ( $pid >> 8 & 0x1f );
        vec( $finalMts, $j + 2, 8 ) = $pid & 0xff;
    } ## end for ( my $j = 0 ; $j < ...)

    return $finalMts;
} ## end sub getEit

=head3 getSectionFrequency( $table_id, $section_number, $timeFrame)

Make lookup by $table_id and $section_number and return how often this section
has to be repeated in the given interval. Default interval ($timeFrame) is 60 seconds.

=cut

sub getSectionFrequency {
    my ( $self, $table_id, $section_number, $timeFrame ) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;

    $timeFrame //= 60;

    # according to some scandinavian and australian specification we use following
    # repetition rate:
    # EITsched actual 1 day      - every 10s
    # EITsched actual other days - every 30s
    # EITsched other 1 day       - every 30s
    # EITsched other other days  - every 30s
    # THE FREQUENCY FOR PRESENT/FOLLOWING TABLE 0x4e AND 0x4f IS DEFINED IN THE CALLING SUBROUTINE
    return ceil( $timeFrame / 10 ) if ( $table_id == 0x50 ) and ( $section_number < ( 1 * 24 / 3 ) );
    return ceil( $timeFrame / 30 );
} ## end sub getSectionFrequency

=head3 getLastError( )

Return last db operation error.

=cut

sub getLastError {
    my ($self) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;

    return $dbh->errstr;
} ## end sub getLastError

=head3 getLogEntry($id)

Get info field from log entry with $id.

=cut

sub getLogEntry {
    my ( $self, $id ) = @_;

    my $dbh = $self->dbh;
    return unless $dbh;

    my $sql       = "SELECT info FROM log WHERE id = ?";
    my $statement = $dbh->prepare($sql);

    if ( $statement->execute($id) ) {
        my $json = $statement->fetchrow_array();

        if ($json) {
            return decode_json($json);
        } else {
            return;
        }
    } else {
        return;
    }
} ## end sub getLogEntry

=head3 getLogList( $categoryList, $level, $start, $limit, $channel_id)

Return list of log records filtered by params

=cut

sub getLogList {
    my ( $self, $categoryList, $level, $start, $limit, $channel_id ) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;

    $level        //= 0;
    $categoryList //= [];
    $start        //= 0;
    $limit        //= 100;

    # build channelFilter
    my $channelFilter = "";
    if ( $channel_id && $channel_id =~ m/^\d+$/ ) {
        $channelFilter = " AND log.channel_id = $channel_id ";
    }

    # count all rows
    my ($total) = $dbh->selectrow_array("SELECT COUNT(*) FROM log");

    # when all 5 categories are selected we don't need to filter
    my $categoryListFilter = '';

    my $categoryListSize = scalar( @{$categoryList} );

    if ( $categoryListSize > 0 and $categoryListSize < 5 ) {
        $categoryListFilter = " AND `category` IN (" . join( ",", @{$categoryList} ) . ") ";
    }

    # count filtered rows
    my $sql        = "SELECT COUNT(*) FROM log WHERE `level` >= ?" . $categoryListFilter . $channelFilter;
    my $statement  = $dbh->prepare($sql);
    my $result     = $statement->execute($level);
    my ($filtered) = $statement->fetchrow_array();

    # get rows
    $sql =
          "SELECT timestamp, CASE "
        . "WHEN category = 0 THEN 'grabber' "
        . "WHEN category = 1 THEN 'ingester' "
        . "WHEN category = 2 THEN 'builder' "
        . "WHEN category = 3 THEN 'player' "
        . "WHEN category = 4 THEN 'system' "
        . "ELSE 'UNKNOWN' END AS category, " . "CASE "
        . "WHEN level = 0 THEN 'trace' "
        . "WHEN level = 1 THEN 'debug' "
        . "WHEN level = 2 THEN 'info' "
        . "WHEN level = 3 THEN 'warn' "
        . "WHEN level = 4 THEN 'error' "
        . "WHEN level = 5 THEN 'fatal' "
        . "ELSE 'UNKNOWN' END AS level, "
        . "text, eit.name AS channel, eit_id, id, "
        . "CASE WHEN log.info IS NULL THEN 0 ELSE 1 END AS hasinfo FROM log AS log "
        . "LEFT JOIN channel AS eit ON log.channel_id = eit.channel_id "
        . "WHERE `level` >= ? "
        . $categoryListFilter
        . $channelFilter
        . "ORDER BY id DESC LIMIT ? OFFSET ?";

    $statement = $dbh->prepare($sql);
    $result    = $statement->execute( $level, $limit, $start );
    my $listRef = $statement->fetchall_arrayref( {} );

    return ( $total, $filtered, $listRef );
} ## end sub getLogList

=head3 cleanupLog ()

Delete log records before start of previous month.

Return number of deleted records.

=cut

sub cleanupLog {
    my ($self) = @_;
    my $dbh = $self->dbh;
    return unless $dbh;

    my $count =
        $self->dbh->do('DELETE FROM log WHERE timestamp < DATE_ADD(LAST_DAY(DATE_SUB(NOW(), INTERVAL 2 MONTH)), INTERVAL 1 DAY)');

    return 0 if $count eq "0E0";
    return $count;
} ## end sub cleanupLog

=head3 import( $scheme)

Import epg scheme from $scheme structure.

=cut

sub import {
    my ( $self, $scheme ) = @_;
    my @success;
    my @error;

    foreach my $channel ( @{ $scheme->{channel} } ) {
        if ( $self->addChannel($channel) ) {
            push( @success, "Channel: " . $channel->{channel_id} . " " . $channel->{name} );
        } else {
            push( @error, "Channel: " . $channel->{channel_id} . " " . $channel->{name} );
        }
    } ## end foreach my $channel ( @{ $scheme...})

    foreach my $eit ( @{ $scheme->{eit} } ) {
        if ( $self->addEit($eit) ) {
            push( @success, "EIT: " . $eit->{eit_id} . " " . $eit->{pid} );
        } else {
            push( @error, "EIT: " . $eit->{eit_id} . " " . $eit->{pid} );
        }
    } ## end foreach my $eit ( @{ $scheme...})

    foreach my $rule ( @{ $scheme->{rule} } ) {
        if ( $self->addRule($rule) ) {
            push( @success, "Rule: " . $rule->{eit_id} . "-" . $rule->{channel_id} );
        } else {
            push( @error, "Rule: " . $rule->{eit_id} . "-" . $rule->{channel_id} );
        }
    } ## end foreach my $rule ( @{ $scheme...})

    return ( \@success, \@error );
} ## end sub import

=head3 export ( )

Export scheme as $scheme structure.
Return scheme structure.

=cut

sub export {
    my ($self) = @_;
    my $theScheme;

    $theScheme->{channel} = [];

    foreach my $channel ( sort { $a->{channel_id} <=> $b->{channel_id} } @{ $self->listChannel() } ) {
        push( @{ $theScheme->{channel} }, $channel );
    }

    my @sortedRule =
        sort {
               $a->{transport_stream_id} <=> $b->{transport_stream_id}
            or $b->{actual}              <=> $a->{actual}
            or $a->{channel_id}          <=> $b->{channel_id}
        } @{ $self->listRule() };

    $theScheme->{rule} = \@sortedRule;

    $theScheme->{eit} = ();

    foreach my $eit ( sort { $a->{eit_id} <=> $b->{eit_id} } @{ $self->listEit() } ) {
        push( @{ $theScheme->{eit} }, $eit );
    }

    return $theScheme;
} ## end sub export

=head3 _unfreezeEvent( $event)

$event is a reference to hash containing elements of a row in event table.
Thaw the info field and update all other keys from field values.

Return reference to updated info hash.

=cut

sub _unfreezeEvent {
    my $row = shift;

    return unless $row;

    my $event = decode_json( $row->{info} );
    $event->{event_id} = $row->{event_id};
    $event->{start}    = $row->{start};
    $event->{stop}     = $row->{stop};
    $event->{duration} = $row->{stop} - $row->{start};
    return $event;
} ## end sub _unfreezeEvent

=head1 AUTHOR

This software is copyright (c) 2019 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;    # End of cherryEpg::Epg
