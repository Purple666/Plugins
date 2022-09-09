package NewAStarAvoid;

use strict;
use Globals;
use Settings;
use Misc;
use Plugins;
use Utils;
use Log qw(message debug error warning);
use Data::Dumper;

Plugins::register('NewAStarAvoid', 'Enables smart pathing using the dynamic aspect of D* Lite pathfinding', \&onUnload);

use constant {
	PLUGIN_NAME => 'NewAStarAvoid',
	ENABLE_MOVE => 1,
	ENABLE_REMOVE => 1,
};

my $hooks = Plugins::addHooks(
	['PathFindingReset', \&on_PathFindingReset, undef], # Changes args
	['AI_pre/manual', \&on_AI_pre_manual, undef],    # Recalls routing
	['packet_mapChange', \&on_packet_mapChange, undef],
);

my $obstacle_hooks = Plugins::addHooks(
	# Mobs
	['add_monster_list', \&on_add_monster_list, undef],
	['monster_disappeared', \&on_monster_disappeared, undef],
	['monster_moved', \&on_monster_moved, undef],
	
	# Players
	['add_player_list', \&on_add_player_list, undef],
	['player_disappeared', \&on_player_disappeared, undef],
	['player_moved', \&on_player_moved, undef],
	
	# Spells
	['packet_areaSpell', \&on_add_areaSpell_list, undef],
	['packet_pre/area_spell_disappears', \&on_areaSpell_disappeared, undef],
);

sub onUnload {
    Plugins::delHooks($hooks);
	Plugins::delHooks($obstacle_hooks);
}

my %mob_nameID_obstacles = (
	1084 => { #black shrom
		weight => 1000,
		dist => 7
	},
	1085 => { #red shrom
		weight => 1000,
		dist => 4
	},
	1368 => { # planta carnivora
		weight => 1000,
		dist => 4
	},
	1372 => { # bode
		weight => 1000,
		dist => 4
	}
);

my %player_name_obstacles = (
	'testCreator' => {
		weight => 1000,
		dist => 4
	}
);

my %area_spell_type_obstacles = (
	'127' => {
		weight => 1000,
		dist => 4
	}
);

my %obstaclesList;

my $mustRePath = 0;

sub on_packet_mapChange {
	undef %obstaclesList;
	$mustRePath = 0;
}

###################################################
######## Main obstacle management
###################################################

sub add_obstacle {
	my ($actor, $obstacle) = @_;
	
	warning "[".PLUGIN_NAME."] Adding obstacle $actor on location ".$actor->{pos}{x}." ".$actor->{pos}{y}.".\n";
	
	my $weight_changes = create_changes_array($actor->{pos}, $obstacle);
	
	$obstaclesList{$actor->{ID}}{pos_to} = $actor->{pos_to};
	$obstaclesList{$actor->{ID}}{weight} = $weight_changes;
	
	$mustRePath = 1;
}

sub move_obstacle {
	my ($actor, $obstacle) = @_;
	
	return unless (ENABLE_MOVE);
	
	warning "[".PLUGIN_NAME."] Moving obstacle $actor (from ".$actor->{pos}{x}." ".$actor->{pos}{y}." to ".$actor->{pos_to}{x}." ".$actor->{pos_to}{y}.").\n";
	
	my $weight_changes = create_changes_array($actor->{pos_to}, $obstacle);
	
	$obstaclesList{$actor->{ID}}{pos_to} = $actor->{pos_to};
	$obstaclesList{$actor->{ID}}{weight} = $weight_changes;
	
	$mustRePath = 1;
}

sub remove_obstacle {
	my ($actor) = @_;
	
	return unless (ENABLE_REMOVE);
	
	warning "[".PLUGIN_NAME."] Removing obstacle $actor from ".$actor->{pos}{x}." ".$actor->{pos}{y}.".\n";
	
	delete $obstaclesList{$actor->{ID}};
	
	$mustRePath = 1;
}

###################################################
######## Tecnical subs
###################################################

sub on_AI_pre_manual {
	return unless (AI::is("route"));
	return unless ($mustRePath);
	
	my $task;
	
	if (UNIVERSAL::isa($char->args, 'Task::Route')) {
		$task = $char->args;
		
	} elsif ($char->args->getSubtask && UNIVERSAL::isa($char->args->getSubtask, 'Task::Route')) {
		$task = $char->args->getSubtask;
		
	} else {
		return;
	}
	
	$mustRePath = 0;
	
	if (scalar @{$task->{solution}} == 0) {
		Log::warning "[test] Route already reseted.\n";
		return;
	}
	
	Log::warning "[test] Reseting route.\n";
	
	$task->resetRoute;
}

sub on_PathFindingReset {
	my (undef, $args) = @_;
	
	my @obstacles = keys(%obstaclesList);
	
	warning "[".PLUGIN_NAME."] on_PathFindingReset before check, there are ".@obstacles." obstacles.\n";
	
	return unless (@obstacles > 0);
	
	Log::warning "[test] Using grided info.\n";
	
	$args->{args}{weight_map} = \(get_final_grid());
	$args->{args}{width} = $args->{args}{field}{width} unless ($args->{args}{width});
	$args->{args}{height} = $args->{args}{field}{height} unless ($args->{args}{height});
	$args->{args}{timeout} = 1500 unless ($args->{args}{timeout});
	$args->{args}{avoidWalls} = 1 unless (defined $args->{args}{avoidWalls});
	$args->{args}{min_x} = 0 unless (defined $args->{args}{min_x});
	$args->{args}{max_x} = ($args->{args}{width}-1) unless (defined $args->{args}{max_x});
	$args->{args}{min_y} = 0 unless (defined $args->{args}{min_y});
	$args->{args}{max_y} = ($args->{args}{height}-1) unless (defined $args->{args}{max_y});
	
	$args->{return} = 0;
}

sub get_final_grid {
	my $grid = $field->{weightMap};
	
	my $changes = sum_all_changes();
	
	foreach my $change (@{$changes}) {
		my $position = $change->{y} * $field->{width} + $change->{x};
		my $current_weight = unpack('C', substr($grid, $position, 1));
		my $weight_changed = $current_weight + $change->{weight};
		#warning "[".PLUGIN_NAME."] after  $change->{x} $change->{y} | $current_weight -> $weight_changed.\n";
		substr($grid, $position, 1, pack('C', $weight_changed));
	}
	
	return $grid;
}

sub get_weight_for_block {
	my ($ratio, $dist) = @_;
	if ($dist == 0) {
		$dist = 1;
	}
	my $weight = int($ratio/($dist*$dist));
	if ($weight >= 127) {
		$weight = 127;
	}
	return $weight;
}

sub create_changes_array {
	my ($obstacle_pos, $obstacle) = @_;
	
	my %obstacle = %{$obstacle};
	
	my $max_distance = $obstacle{dist};
	my $ratio = $obstacle{weight};
	
	my @changes_array;
	
	my ($min_x, $min_y, $max_x, $max_y) = Utils::getSquareEdgesFromCoord($field, $obstacle_pos, $max_distance);
	
	my @y_range = ($min_y..$max_y);
	my @x_range = ($min_x..$max_x);
	
	foreach my $y (@y_range) {
		foreach my $x (@x_range) {
			next unless ($field->isWalkable($x, $y));
			my $pos = {
				x => $x,
				y => $y
			};
			
			my $distance = adjustedBlockDistance($pos, $obstacle_pos);
			my $delta_weight = get_weight_for_block($ratio, $distance);
			#warning "[".PLUGIN_NAME."] $x $y ($distance) -> $delta_weight.\n";
			push(@changes_array, {
				x => $x,
				y => $y,
				weight => $delta_weight
			});
		}
	}
	
	@changes_array = sort { $b->{weight} <=> $a->{weight} } @changes_array;
	
	return \@changes_array;
}

sub sum_all_changes {
	my %changes_hash;
	
	#warning "[".PLUGIN_NAME."] 1 obstaclesList: ". Data::Dumper::Dumper \%obstaclesList;
	
	foreach my $key (keys %obstaclesList) {
		warning "[".PLUGIN_NAME."] sum_all_avoid - testing obstacle at $obstaclesList{$key}{pos_to}{x} $obstaclesList{$key}{pos_to}{y}.\n";
		foreach my $change (@{$obstaclesList{$key}{weight}}) {
			my $x = $change->{x};
			my $y = $change->{y};
			my $changed = $change->{weight};
			$changes_hash{$x}{$y} += $changed;
		}
	}
	
	my @rebuilt_array;
	foreach my $x_keys (keys %changes_hash) {
		foreach my $y_keys (keys %{$changes_hash{$x_keys}}) {
			next if ($changes_hash{$x_keys}{$y_keys} == 0);
			push(@rebuilt_array, { x => $x_keys, y => $y_keys, weight => $changes_hash{$x_keys}{$y_keys} });
		}
	}
	
	#warning "[".PLUGIN_NAME."] 2 rebuilt: ". Data::Dumper::Dumper \@rebuilt_array;
	
	return \@rebuilt_array;
}

###################################################
######## Player avoiding
###################################################

sub on_add_player_list {
	my (undef, $args) = @_;
	my $actor = $args;
	
	return unless (exists $player_name_obstacles{$actor->{name}});
	
	my %obstacle = %{$player_name_obstacles{$actor->{name}}};
	
	add_obstacle($actor, \%obstacle);
}

sub on_player_moved {
	my (undef, $args) = @_;
	my $actor = $args;
	
	return unless (exists $obstaclesList{$actor->{ID}});
	
	my %obstacle = %{$player_name_obstacles{$actor->{name}}};
	
	move_obstacle($actor, \%obstacle);
}

sub on_player_disappeared {
	my (undef, $args) = @_;
	my $actor = $args->{player};
	
	return unless (exists $obstaclesList{$actor->{ID}});
	
	remove_obstacle($actor);
}

###################################################
######## Mob avoiding
###################################################

sub on_add_monster_list {
	my (undef, $args) = @_;
	my $actor = $args;
	
	return unless (exists $mob_nameID_obstacles{$actor->{nameID}});
	
	my %obstacle = %{$mob_nameID_obstacles{$actor->{nameID}}};
	
	add_obstacle($actor, \%obstacle);
}

sub on_monster_moved {
	my (undef, $args) = @_;
	my $actor = $args;

	return unless (exists $obstaclesList{$actor->{ID}});
	
	my %obstacle = %{$mob_nameID_obstacles{$actor->{nameID}}};
	
	move_obstacle($actor, \%obstacle);
}

sub on_monster_disappeared {
	my (undef, $args) = @_;
	my $actor = $args->{monster};
	
	return unless (exists $obstaclesList{$actor->{ID}});
	
	remove_obstacle($actor);
}

###################################################
######## Spell avoiding
###################################################

# TODO: Add fail flag check

sub on_add_areaSpell_list {
	my (undef, $args) = @_;
	my $ID = $args->{ID};
	my $spell = $spells{$ID};
	
	return unless (exists $area_spell_type_obstacles{$spell->{type}});
	
	my %obstacle = %{$area_spell_type_obstacles{$spell->{type}}};
	
	add_obstacle($spell, \%obstacle);
}

sub on_areaSpell_disappeared {
	my (undef, $args) = @_;
	my $ID = $args->{ID};
	my $spell = $spells{$ID};
	
	return unless (exists $obstaclesList{$spell->{ID}});
	
	remove_obstacle($spell);
}

return 1;