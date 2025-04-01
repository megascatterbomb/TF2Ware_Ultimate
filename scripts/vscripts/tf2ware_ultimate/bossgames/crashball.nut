minigame <- Ware_MinigameData
({
	name           = "Crashball"
	author         = ["megascatterbomb"]
	description    = "Defend your goal!"
	duration       = INT_MAX.tofloat() // actual duration varies wildly depending on playercount.
    min_players    = 2
	location       = "crashball"
	music          = "crashball"
    thirdperson    = true
	fail_on_death  = true
	start_freeze   = 0.5
})

max_players_per_arena <- 4 // DO NOT CHANGE.
absolute_max_rounds <- 1 // Incremented in OnStart based on starting player count. Initial definition acts as an offset.

goal_distance_from_center <- 336.0 // If a ball is this far from the center of the arena, it will score.
player_distance_from_center <- 304.0 // Players spawn this far from the center of the arena.
targetname_prefix <- "crashball" // Prefix for all entities in the arenas.

timestamp_round_start <- Time() // Time when the current round started.
timestamp_last_update <- Time() // Time when the last update occurred.

remaining_playercount <- 101 // Number of players remaining in the minigame.

ball_model <- "models/tf2ware_ultimate/big_soccer_ball.mdl"
ball_scale <- 1
ball_min_velocity <- 100.0

enum CrashballState
{
	Setup = 0
	Gaming = 1
	Ending = 2
	Finished = 3
	Cleaned = 4
}

round_number <- 0
current_round <- null
current_state <- 0

active_round <- null

// CRASHBALL CLASSES

class CrashballRound {
	// REQUIRED
	player_groups = null // Array of arrays of player handles for the players in each arena.

	// OPTIONAL
	round_config = null

	// INTERNAL
	arenas = [] // Array of CrashballArena objects.
	function constructor(table = null)
	{
		round_config = {} // Arena configuration.

		if (table)
		{
			foreach (key, value in table)
				this[key] = value
		}
	}

	function Setup()
	{
		foreach(group, index in player_groups)
		{
			local arena_config = round_config

			arena_config.players <- group
			arena_config.index <- index

			arenas.append(CrashballArena(arena_config))
		}

		foreach (arena in arenas)
		{
			arena.Setup()
		}
	}

	function UpdateScoreboards(forced_message = null)
	{
		foreach (arena in arenas)
		{
			arena.UpdateScoreboard(forced_message)
		}
	}

	function Start()
	{
		foreach (arena in arenas)
		{
			arena.Start()
		}
		current_state = CrashballState.Gaming
	}

	function Update()
	{
		remaining_playercount = active_players.len()

		foreach (arena in arenas)
		{
			arena.Update()
		}
	}

	function TransitionToEnd()
	{
		if (current_state = CrashballState.Gaming)
		{
			current_state = CrashballState.Ending
			foreach (arena in arenas)
			{
				arena.TransitionToEnd()
			}
			return true
		}
		return false
	}

	function End()
	{
		current_state = CrashballState.Finished
		Ware_CreateTimer(@() CleanupCrashballRound(), 3.0)
	}

	function CheckIfAllArenasFinished()
	{
		foreach (arena in arenas)
		{
			if (arena.arena_state != CrashballState.Finished)
			{
				return false;
			}
		}
		End()
		return true;
	}

	function Cleanup()
	{
		foreach (arena in arenas)
		{
			arena.Cleanup()
		}
		current_state = CrashballState.Cleaned
	}
}

class CrashballArena {
	// Arrays are always ordered north-south-east-west (+y, -y, +x, -x)
	// REQUIRED
	players = null // Array of player handles for players in this arena.
	index = null // Index of the arena. Valid values 0 to 24.

	// OPTIONAL
	final = null
	lives = null
	min_duration_before_countdown = null
	max_duration_before_countdown = null
	max_dead_before_countdown = null
	countdown_duration = null
	ball_limit_increase_times = null
	max_winners = null
	ties_win = null

	// INTERNAL
	arena_state = CrashballState.Setup
	ball_last_spawn = Time()
	ball_limit = 0
	point_template = null
	center = null
	point_worldtext = null
	env_lasers = []
	func_brushes = []

	function constructor(table = null)
	{
		lives = 15 // Number of lives each player starts with.

		final = false // If true, this is the final round.

		min_duration_before_countdown = 60.0 // Minimum duration of the game before the countdown starts.
		max_duration_before_countdown = 120.0 // Maximum duration of the game before the countdown starts.
		max_dead_before_countdown = 0.5 // Maximum ratio of players that can die across all active arenas before the countdown starts.
		countdown_duration = 30.0 // Countdown duration.

		// Ball limit starts at 0, increments over time.
		// The arena will always try to keep the ball count at the current limit.
		// Values define when the ball limit increments (in seconds).
		// Do not set the first value to anything other than 0.0 unless something special needs to happen at the start of the game.
		ball_limit_increase_times = [0.0, 10.0, 30.0, 60.0, 90.0]

		// If after a timeout the leading players have the same number of lives left:
		// everyone either wins (true) or loses (false) depending on this value.
		ties_win = true

		if (table)
		{
			foreach (key, value in table)
				this[key] = value
		}
	}

	function Setup()
	{
		// Activate the template
		point_template = GetArenaEnt("template_a")
		point_template.AcceptInput("ForceSpawn")

		// Set all players to the same class (Pyro)
		// Give them just the Dragon's fury (for airblasting balls) and set their health accordingly.
		local health_penalty = 175 - lives

		foreach(player in players)
		{
			Ware_SetPlayerLoadout(player, TF_CLASS_PYRO, "Dragon's Fury", {"max health additive penalty": health_penalty})
		}

		foreach(player in players)
		{
			player.SetHealth(lives)
		}

		// Teleport players into position
		center = point_template.GetOrigin()
		local player_positions = [
			center + Vector(0, player_distance_from_center, 0),
			center + Vector(0, -player_distance_from_center, 0),
			center + Vector(player_distance_from_center, 0, 0),
			center + Vector(-player_distance_from_center, 0, 0)
		]
		local player_angles = [
			QAngle(0, -90, 0),
			QAngle(0, 90, 0),
			QAngle(0, 180, 0),
			QAngle(0, 0, 0)
		]

		foreach(player, index in players)
		{
			Ware_TeleportPlayer(player, player_positions[index], player_angles[index], vec3_zero)
		}

		// Get handles for other entities

		env_lasers = [
			GetArenaEnt("laser_north"),
			GetArenaEnt("laser_south"),
			GetArenaEnt("laser_east"),
			GetArenaEnt("laser_west")
		]

		func_brushes = [
			GetArenaEnt("wall_north"),
			GetArenaEnt("wall_south"),
			GetArenaEnt("wall_east"),
			GetArenaEnt("wall_west")
		]

		point_worldtext = GetArenaEnt("scoreboard")

		UpdateScoreboard()

		// Wall off unused sides for 2 and 3 player games
		if (players <= 2)
		{
			env_lasers[2].AcceptInput("TurnOn", "", null, null)
			func_brushes[2].AcceptInput("Enable", "", null, null)
		}
		if (players <= 3)
		{
			env_lasers[3].AcceptInput("TurnOn", "", null, null)
			func_brushes[3].AcceptInput("Enable", "", null, null)
		}
	}

	function Start()
	{
		arena_state = CrashballState.Gaming
		foreach(timestamp in ball_limit_increase_times)
		{
			Ware_CreateTimer(@() this.ball_limit++, timestamp)
		}
	}

	function Update()
	{
		// Spawn balls if needed
		local balls = GetAllArenaEnts("ball")
		if (Time() - ball_last_spawn >= 1.0 && balls.len() < ball_limit)
		{
			ball_last_spawn = Time()
			SpawnBall()
		}

		// Update ball Velocities, check for balls in goal
		foreach (ball in balls)
		{
			// Check if ball is in a goal
			local ball_origin = ball.GetOrigin()
			local ball_velocity = ball.GetPhysVelocity()
			local min_velocity_squared = ball_min_velocity * ball_min_velocity

			if (ball_origin.y > goal_distance_from_center)
			{
				ScoreGoal(ball, 0)
			}
			else if (-ball_origin.y > goal_distance_from_center)
			{
				ScoreGoal(ball, 1)
			}
			else if (ball_origin.x > goal_distance_from_center)
			{
				ScoreGoal(ball, 2)
			}
			else if (-ball_origin.x > goal_distance_from_center) {
				ScoreGoal(ball, 3)
			}
			// Set ball velocity to a minimum value (else-if because the previous ifs will delete the ball!)
			else if (ball_velocity.x * ball_velocity.x + ball_velocity.y + ball_velocity.y < min_velocity_squared)
			{
				local new_velocity = (ball_velocity * 1.05) + Vector(RandomFloat(1.0, 5.0), RandomFloat(1.0, 5.0), 0)
				new_velocity.z = 0
				ball.SetPhysVelocity(new_velocity)
			} else {
				ball_velocity.z = 0
				ball.SetPhysVelocity(ball_velocity)
			}
		}

		UpdateScoreboard()
	}

	function SpawnBall()
	{
		local ball = Ware_SpawnEntity("prop_soccer_ball", {
			targetname = format("%s_ball-%d", targetname_prefix, index)
			model = ball_model,
			origin = center,
			skin = 0
		})

		local init_velocity = Vector(RandomFloat(10.0, 100.0), RandomFloat(10.0, 100.0), 0)

		ball.SetPhysVelocity(init_velocity)
	}

	function ScoreGoal(ball, player_index)
	{
		local player = player_index < players.len() ? players[player_index] : null
		if (player && player.IsValid() && player.IsAlive())
		{
			if (player.GetHealth() == 1) // They about to lose
			{
				env_lasers[player_index].AcceptInput("TurnOn", "", null, null)
				func_brushes[player_index].AcceptInput("Enable", "", null, null)
			}

			local vecPunch = GetPropVector(boss, "m_Local.m_vecPunchAngle");
			player.TakeDamageCustom(player, player, null, Vector(0.0000001, 0.0000001, 0.0000001), ball.GetOrigin(), 1, DMG_PREVENT_PHYSICS_FORCE, TF_DMG_CUSTOM_PLASMA);
			SetPropVector(boss, "m_Local.m_vecPunchAngle", vecPunch);
		}

		ball.Kill()
	}

	function TransitionToEnd()
	{
		if (arena_state != CrashballArena.Gaming) return;
		arena_state = CrashballState.Ending

		// Determine winner(s) of this arena
		local survivors = players.filter(@(p) p && p.IsValid() && p.IsAlive())

		survivors.sort(@(a, b) a.GetHealth() > b.GetHealth())

		local winners = []

		foreach(survivor in survivors) {
			if (winners.len() == 0 || winners[0].GetHealth() == survivor.GetHealth())
			{
				if(winners.len() > 0 && !ties_win)
				{
					winners.clear()
					break
				}
				winners.append(survivor)
				continue
			}
			break
		}

		// We now have our winners. Kill the others
		local winner_indices = winners.map(@(w) players.find(w)).filter(@(i) i != null)

		foreach(player, i in players)
		{
			if (winner_indices.find(i) != null) continue;

			env_lasers[i].AcceptInput("TurnOn", "", null, null)
			func_brushes[i].AcceptInput("Disable", "", null, null)
		}

		Ware_CreateTimer(@() this.End(), 1.0)
	}

	function End()
	{
		if (arena_state != CrashballArena.Ending) return;
		foreach(player, i in players)
		{
			env_lasers[i].AcceptInput("TurnOff", "", null, null)
			func_brushes[i].AcceptInput("Disable", "", null, null)
		}

		remaining_playercount = Ware_GetAlivePlayers().len()

		UpdateScoreboard()

		arena_state = CrashballState.Finished
	}

	function Cleanup()
	{
		// Remove all balls.
		foreach(ball in GetAllArenaEnts("ball"))
		{
			ball.Kill()
		}

		foreach(ent in env_lasers)
		{
			ent.Kill()
		}
		env_lasers = []
		foreach(ent in [
			GetArenaEnt("laser_north_target")
			GetArenaEnt("laser_south_target")
			GetArenaEnt("laser_east_target")
			GetArenaEnt("laser_west_target")
		])
		{
			ent.Kill()
		}
		foreach (ent in func_brushes)
		{
			ent.Kill()
		}
		func_brushes = []
		point_worldtext.Kill()
		point_worldtext = null
		arena_state = CrashballState.Cleaned
	}

	function GetArenaEnt(name, previous = null)
	{
		return FindByName(previous, format("%s_%s-%d", targetname_prefix, name, index))
	}

	function GetAllArenaEnts(name)
	{
		local ents = []
		for (local ent = null; ent = GetArenaEnt(name, ent);)
		{
			ents.append(ent)
		}
		return ents
	}

	function GetLivesRemainingString(player)
	{
		if (!player || !player.IsValid()) return "unconnected: 0"
		local name = GetPropString(player, "m_szNetname");
		local lives_left = player.IsAlive() ? player.GetHealth() : 0;

		return format("%s: %d", name, lives_left);
	}

	function UpdateScoreboard(forced_message = null)
	{
		if(forced_message)
		{
			point_worldtext.AcceptInput("SetText", forced_message, null, null)
			return
		}
		switch (arena_state)
		{
			case CrashballState.Setup:
				if (round_number == 1)
				{
					point_worldtext.AcceptInput("SetText", "DEFEND YOUR GOAL!", null, null)
				}
				else if (final)
				{
					point_worldtext.AcceptInput("SetText", format("%d PLAYERS REMAIN!\nFINAL ROUND!", remaining_playercount), null, null)
				}
				else
				{
					point_worldtext.AcceptInput("SetText", format("%d PLAYERS REMAIN!\nROUND %d", remaining_playercount, round_number), null, null)
				}
				break
			case CrashballState.Gaming:
			case CrashballState.Ending:
				// Show scores for players in this arena.
				local message = "LIVES REMAINING:"

				// Show scores in clockwise order from the north during gameplay.
				if (players.len() >= 1) message += "\n" + GetLivesRemainingString(players[0])
				if (players.len() >= 3) message += "\n" + GetLivesRemainingString(players[2])
				if (players.len() >= 2) message += "\n" + GetLivesRemainingString(players[1])
				if (players.len() >= 4) message += "\n" + GetLivesRemainingString(players[3])

				point_worldtext.AcceptInput("SetText", message, null, null)

				break
			case CrashballState.Finished:
				// If final, declare the winners.
				if (final)
				{
					local winners;
					local message = "";
					foreach (player in players)
					{
						if (player && player.IsValid() && player.IsAlive()) winners.append(player)
					}
					if (winners.len() == 0)
					{
						message = "YOU ALL LOST!"
					}
					else if (winners.len() == 1)
					{
						local name = GetPropString(winners[0], "m_szNetname");
						message = format("%s WINS!", remaining_playercount, name)
					}
					else
					{
						message = "WINNERS:"
						foreach(player, i in winners)
						{
							message += "\n" + GetPropString(player, "m_szNetname")
						}
					}
				}
				else
				{
					local survivors;
					local message = "";
					foreach (player in players)
					{
						if (player && player.IsValid() && player.IsAlive()) survivors.append(player)
					}
					if (survivors.len() == 0)
					{
						message = remaining_playercount == 0 ? "YOU ALL LOST!" : format("%d PLAYERS REMAIN!\nNONE OF YOU MADE IT...", remaining_playercount)
					}
					else if (survivors.len() == 1)
					{
						local name = GetPropString(survivors[0], "m_szNetname");
						message = format("%d PLAYERS REMAIN!\n%s ADVANCES!", remaining_playercount, name)
					}
					else
					{
						message = format("%d PLAYERS REMAIN!\nTHESE PLAYERS ADVANCE:", remaining_playercount)
						foreach (player in survivors)
						{
							message += "\n" + GetPropString(player, "m_szNetname")
						}
					}
					point_worldtext.AcceptInput("SetText", message, null, null)
				}
				break
			default:
				return;
		}
	}
}

// CRASHBALL FUNCTIONS

function StartCrashballRound()
{
	round_number++
	active_players = Ware_GetAlivePlayers()
	remaining_playercount = active_players.len()

	if (remaining_playercount <= 1 || (current_round && current_round.final))
	{
		// We have a winner!
		foreach(player in active_players)
		{
			Ware_PassPlayer(active_players)
		}
		Ware_CreateTimer(@() Ware_EndMinigame(), 1.0)
		return
	}

	// Round actually starts here.

	// *theoretically* the game could go on forever if everyone ties in every round.
	// To stop this, absolute_max_rounds is set to 1 above the expected amount of rounds.
	// Realistically 99.9% of games should end in the expected amount of rounds.
	local is_final = (current_round && current_round.final)
		|| active_players.len() <= max_players_per_arena
		|| round_number >= absolute_max_rounds

    current_round = CrashballRound({
		player_groups = DividePlayersIntoArenas()
		round_config = GetRoundConfig(is_final)
	})

    current_round.Setup()

	// TODO: Countdown sounds
	Ware_CreateTimer(@() current_round.UpdateScoreboards("3..."), 3.0)
	Ware_CreateTimer(@() current_round.UpdateScoreboards("2..."), 4.0)
	Ware_CreateTimer(@() current_round.UpdateScoreboards("1..."), 5.0)
	Ware_CreateTimer(@() current_round.UpdateScoreboards("GO!"), 6.0)
    Ware_CreateTimer(@() current_round.Start(), 7.0)
}

// Divide players into arenas.
// Arenas are divided to maximise the number of players in each arena.
// Every arena will always have at least 3 players, unless there are exactly 2 or 5 players.
// Returns array of arrays of player handles.
function DividePlayersIntoArenas()
{
	local players = clone(active_players)
	local groups = []

	function CreateGroup(size)
	{
		local group = []
		for (local i = 0; i < size; i++)
			group.append(RemoveRandomElement(players))
		groups.append(group)
	}
	// hardcoded for arena size of 4 but I don't care.
	for (;;)
	{
		switch (players.len())
		{
			case 0:
				return groups
			case 1:
				// We should never end up here.
				throw "DividePlayersIntoArenas: 1 player left over!"
			case 2:
				CreateGroup(2)
				break
			case 3:
			case 5: // want 3-2 split
			case 6: // want 3-3 split
			case 9: // want 3-3-3 split
				CreateGroup(3)
				break
			default:
				CreateGroup(4)
				break
		}
	}
}

// Final round is full length, other rounds are progressively shorter.
function GetRoundConfig(is_final)
{
    if (is_final)
    {
        return {
            final = true
            lives = 20
            min_duration_before_countdown = 120.0
            max_duration_before_countdown = 150.0
            max_dead_before_countdown = 0.5
            ball_limit_increase_times = [0.0, 10.0, 30.0, 60.0, 90.0, 120.0, 150.0]
            countdown_duration = 30.0
        }
    }
    switch (round_number)
    {
        case 1:
            return {
                lives = 15
                min_duration_before_countdown = 60.0
		        max_duration_before_countdown = 90.0
                max_dead_before_countdown = 0.25
                countdown_duration = 30.0
                ball_limit_increase_times = [0.0, 10.0, 30.0, 60.0, 90.0]
            }
        case 2:
            return {
                lives = 12
                min_duration_before_countdown = 50.0
		        max_duration_before_countdown = 80.0
                max_dead_before_countdown = 0.3
                countdown_duration = 30.0
                ball_limit_increase_times = [0.0, 8.0, 20.0, 40.0, 70.0]
            }
        default:
            return {
                lives = 10
                min_duration_before_countdown = 45.0
		        max_duration_before_countdown = 70.0
                max_dead_before_countdown = 0.35
                countdown_duration = 30.0
                ball_limit_increase_times = [0.0, 5.0, 15.0, 30.0, 50.0]
            }
    }
}

function EndCrashballRound()
{
	current_round.TransitionToEnd()
}

function CleanupCrashballRound()
{
	if (current_round) current_round.Cleanup()
	current_round = null
}

// TF2WARE API FUNCTIONS

function OnPrecache()
{
	// precache music

	// precache ball model

	// precache sounds

	// precache models
}

function OnTeleport()
{
	// do nothing: we handle teleports during the round.
}

function OnStart()
{
	active_players = Ware_GetAlivePlayers()
	remaining_playercount = active_players.len()

	local i = active_players.len()
	while (i > 1)
	{
		absolute_max_rounds++
		i = ceil(i.tofloat() / max_players_per_arena)
	}

	StartCrashballRound()
}


function OnUpdate()
{
	remaining_playercount = Ware_GetAlivePlayers().len()
    if (current_state == CrashballState.Gaming && current_round) current_round.Update()
	else if (current_state == CrashballState.Ending && current_round) current_round.CheckIfAllArenasFinished()
}

function OnCheckEnd()
{
	return false
}

function OnEnd()
{

}

function OnCleanup()
{

}