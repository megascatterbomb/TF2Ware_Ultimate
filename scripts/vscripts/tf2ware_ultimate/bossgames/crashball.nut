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

arena_size <- 336.0 // If a ball is this far from the center of the arena, it will score.
player_distance_from_center <- 304.0 // Players spawn this far from the center of the arena.
targetname_prefix <- "crashball" // Prefix for all entities in the arenas.

ball_model <- "models/tf2ware_ultimate/big_soccer_ball.mdl"
ball_scale <- 1

enum CrashballState
{
	Setup = 0
	Gaming = 1
	Countdown = 2
	Postgame = 3
}

round_number <- 0
current_round <- null
current_state <- 0

active_round <- null

// CRASHBALL CLASSES

class CrashballRound {
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
		foreach (index, group in player_groups)
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

	function Start()
	{
		foreach (arena in arenas)
		{
			arena.Start()
		}
	}

	function Update()
	{
		foreach (arena in arenas)
		{
			arena.Update()
		}
	}

	function End()
	{
		foreach (arena in arenas)
		{
			arena.End()
		}
	}

	function Cleanup()
	{
		foreach (arena in arenas)
		{
			arena.Cleanup()
		}
	}
    // REQUIRED
    player_groups = null // Array of arrays of player handles for the players in each arena.

	// OPTIONAL
	round_config = null

	// INTERNAL
	arenas = [] // Array of CrashballArena objects.
}

class CrashballArena {
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

		// Maximum number of winners for this arena in event of timeout.
		// Winners progress to the next round, or are awarded points if it's the final round.
		// If a tie, then players involved in the tie win or lose depending on the ties_win value.
		max_winners = 1
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
		// Give them just the Dragon's fury (for airblasting balls)

		local health_penalty = 175 - lives

		foreach(player in players)
		{
			Ware_SetPlayerLoadout(player, TF_CLASS_PYRO, "Dragon's Fury", {"max health additive penalty": health_penalty})
		}

		// Teleport players into position
		center = point_template.GetAbsOrigin()
		local player_positions = [
			center + Vector(0, player_distance_from_center, 0),
			center + Vector(0, -player_distance_from_center, 0),
			center + Vector(player_distance_from_center, 0, 0),
			center + Vector(-player_distance_from_center, 0, 0)
		]

		foreach(player, index in players)
		{
			Ware_TeleportPlayer(player, player_positions[index])
		}

		// Set players health
		foreach(player in players)
		{
			player.SetHealth(lives)
		}
	}

	function Start()
	{
		// TODO
	}

	function Update()
	{
		// TODO
	}

	function End()
	{
		// TODO
	}

	function Cleanup()
	{
		// TODO
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
	balls = [] // balls
	ball_limit = 0
	point_template = null
	center = null
	env_lasers = []
	func_brushes = []
}

// CRASHBALL FUNCTIONS

function StartCrashballRound()
{
	round_number++
	active_players = Ware_GetAlivePlayers()

	if (active_players.len() <= 1 || (current_round && current_round.final))
	{
		// We have a winner!
		foreach(player in active_players)
		{
			Ware_PassPlayer(active_players)
		}
		Ware_CreateTimer(@() Ware_EndMinigame(), 2.0)
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

    Ware_CreateTimer(@() current_round.Start(), 5.0)
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

}

function CleanupCrashballRound()
{

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
    if (current_round) current_round.Update()
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