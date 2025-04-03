minigame <- Ware_MinigameData
({
	name           = "Crashball"
	author         = ["megascatterbomb"]
	description    = "Defend your goal!"
	duration       = INT_MAX.tofloat() // actual duration varies wildly depending on playercount.
    min_players    = 2
	location       = "crashball"
	music          = "frogger"
	custom_overlay = ""
    thirdperson    = true
	fail_on_death  = true
	start_freeze   = 0.5
})

local max_players_per_arena = 4 // DO NOT CHANGE.
local absolute_max_rounds = 1 // Incremented in OnStart based on starting player count. Initial definition acts as an offset.

local goal_distance_from_center = 336.0 // If a ball is this far from the center of the arena, it will score.
local player_distance_from_center = 304.0 // Players spawn this far from the center of the arena.
local player_size = 40
local targetname_prefix = "crashball" // Prefix for all entities in the arenas.

local timestamp_round_start = Time() // Time when the current round started.

local remaining_playercount = 101 // Number of players remaining in the minigame.

local ball_model = "models/tf2ware_ultimate/big_soccer_ball.mdl"
local ball_scale = 1
local ball_min_velocity = 300.0

enum CrashballState
{
	Setup = 0
	Gaming = 1
	Ending = 2
	Finished = 3
	Cleaned = 4
}

local round_number = 0
local current_round = null
local current_state = CrashballState.Setup
local last_state_change = Time()
local final_round = false

// CRASHBALL CLASSES

local CrashballArena = class {
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
	arena_start_timestamp = Time()
	ball_last_spawn = Time()
	countdown_start = null
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
		point_template.AcceptInput("ForceSpawn", "", null, null)

		// Set all players to the same class (Spy)
		// Give them just the Knife (for knocking balls) and set their health accordingly.
		local health_penalty = 125 - lives

		foreach(player in players)
		{
			Ware_SetPlayerLoadout(player, TF_CLASS_SPY, "Knife", {"max health additive penalty": -health_penalty})
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

		foreach(index, player in players)
		{
			// FIXME: For some reason this teleport fails after round 1, even though I've quadruple-checked
			// it's being fed the correct values AND Ware_TeleportPlayer is not being called elsewhere!
			Ware_TeleportPlayer(player, player_positions[index], player_angles[index], vec3_zero)
		}

		// Get handles for other entities

		env_lasers = [
			[GetArenaEnt("laser_north_left"), GetArenaEnt("laser_north_right")],
			[GetArenaEnt("laser_south_left"), GetArenaEnt("laser_south_right")],
			[GetArenaEnt("laser_east_left"), GetArenaEnt("laser_east_right")],
			[GetArenaEnt("laser_west_left"), GetArenaEnt("laser_west_right")]
		]

		func_brushes = [
			GetArenaEnt("wall_north"),
			GetArenaEnt("wall_south"),
			GetArenaEnt("wall_east"),
			GetArenaEnt("wall_west")
		]

		point_worldtext = Ware_SpawnEntity("point_worldtext", {
			angles = "0 0 0"
			color = "255 255 255 255"
			font = "0"
			origin = center + Vector(0, 0, 192)
			orientation = "2"
			textsize = "16"
			textspacing = "-18"
			targetname = format("%s_scoreboard-%d", targetname_prefix, index)
		})

		UpdateScoreboard()

		// Wall off unused sides for 2 and 3 player games
		if (players.len() <= 2)
		{
			SetLaser(2, true)
			SetWall(2, true)
		}
		if (players.len() <= 3)
		{
			SetLaser(3, true)
			SetWall(3, true)
		}
	}

	function Start()
	{
		arena_state = CrashballState.Gaming
		arena_start_timestamp = Time()
		foreach(timestamp in ball_limit_increase_times)
		{
			Ware_CreateTimer(@() IncrementBallLimit(), timestamp)
		}
	}

	function Update()
	{
		if (arena_state != CrashballState.Gaming) return;
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

			if (ball_origin.y > center.y + goal_distance_from_center)
			{
				ScoreGoal(ball, 0)
			}
			else if (ball_origin.y < center.y - goal_distance_from_center)
			{
				ScoreGoal(ball, 1)
			}
			else if (ball_origin.x > center.x + goal_distance_from_center)
			{
				ScoreGoal(ball, 2)
			}
			else if (ball_origin.x < center.x - goal_distance_from_center)
			{
				ScoreGoal(ball, 3)
			}
		}
		foreach(ball in balls)
		{
			if (!ball || !ball.IsValid()) continue

			local ball_origin = ball.GetOrigin()
			local ball_velocity = ball.GetPhysVelocity()
			local player_size_squared = player_size * player_size

			// default prop_soccer_ball physics is a bit unreliable, give a helping hand for deflecting
			foreach(i, player in players)
			{
				if (!player || !player.IsValid() || !player.IsAlive() || (ball_origin - player.GetOrigin()).Length2DSqr() > player_size_squared) continue
				switch (i) {
					case 0: // north (+y), deflect towards -y
						if (ball_velocity.y > -ball_min_velocity) ball_velocity.y = -ball_min_velocity
						break
					case 1: // south (-y), deflect towards +y
						if (ball_velocity.y < ball_min_velocity) ball_velocity.y = ball_min_velocity
						break
					case 2: // east (+x), deflect towards -x
						if (ball_velocity.x > -ball_min_velocity) ball_velocity.x = -ball_min_velocity
						break
					case 3: // west (-x), deflect towards +x
						if (ball_velocity.x < ball_min_velocity) ball_velocity.x = ball_min_velocity
						break
				}
				ball.SetPhysVelocity(ball_velocity)
			}

			local ball_velocity_squared = ball_velocity.Length2DSqr()
			local min_velocity_squared = ball_min_velocity * ball_min_velocity

			// Set ball velocity to a minimum value
			if (ball_velocity_squared < min_velocity_squared)
			{
				local new_velocity = (ball_velocity * 1.2)
				if(ball_velocity_squared < 100.0) {
					local new_velocity = Vector(
						RandomInt(0, 1) ? RandomFloat(10.0, ball_min_velocity) : RandomFloat(-10.0, -ball_min_velocity),
						RandomInt(0, 1) ? RandomFloat(10.0, ball_min_velocity) : RandomFloat(-10.0, -ball_min_velocity),
						0)
				}

				if (new_velocity.z > 10.0) new_velocity.z = 10.0
				ball_velocity = new_velocity
				ball.SetPhysVelocity(new_velocity)
			} else {
				if (ball_velocity.z > 10.0) ball_velocity.z = 10.0
				ball.SetPhysVelocity(ball_velocity)
			}
		}

		// Check for end-of-game
		local living_players = 0
		foreach(i, player in players)
		{
			if (player && player.IsValid() && player.IsAlive()) living_players++
		}

		if (living_players <= 1 || (countdown_start && Time() - countdown_start > countdown_duration))
		{
			TransitionToEnd()
		}
		else if (!countdown_start && Time() - arena_start_timestamp > max_duration_before_countdown)
		{
			countdown_start = Time()
		}
		else if (!countdown_start && Time() - arena_start_timestamp > min_duration_before_countdown
			&& living_players.tofloat() / players.len() >= max_dead_before_countdown)
		{
			countdown_start = Time()
		}

		UpdateScoreboard()
	}

	function IncrementBallLimit()
	{
		ball_limit++
	}

	function SpawnBall()
	{
		local offset = Vector(0, 0, 64)
		local ball = Ware_SpawnEntity("prop_soccer_ball", {
			targetname = format("%s_ball-%d", targetname_prefix, index)
			model = ball_model,
			origin = center + offset,
			massscale = 1000
			skin = 0
		})

		local init_velocity = Vector(RandomFloat(-10.0, 10.0), RandomFloat(-10.0, 10.0), 0)

		ball.SetPhysVelocity(init_velocity)
	}

	function ScoreGoal(ball, player_index)
	{
		local player = player_index < players.len() ? players[player_index] : null
		if (arena_state == CrashballState.Gaming && player && player.IsValid() && player.IsAlive())
		{
			if (player.GetHealth() == 1) // They about to lose
			{
				SetLaser(player_index, true)
				SetWall(player_index, true)
			}

			local vecPunch = GetPropVector(player, "m_Local.m_vecPunchAngle");
			player.TakeDamageCustom(player, player, null, Vector(0.0000001, 0.0000001, 0.0000001), ball.GetOrigin(), 1, DMG_BURN + DMG_PREVENT_PHYSICS_FORCE, TF_DMG_CUSTOM_PLASMA);
			SetPropVector(player, "m_Local.m_vecPunchAngle", vecPunch);
		}

		ball.Kill()
	}

	function SetLaser(index, state)
	{
		foreach(laser in env_lasers[index])
		{
			if (laser && laser.IsValid()) laser.AcceptInput(state ? "TurnOn" : "TurnOff", "", null, null)
		}
	}

	function SetWall(index, state)
	{
		func_brushes[index].AcceptInput(state ? "Enable" : "Disable", "", null, null)
	}

	function TransitionToEnd()
	{
		if (arena_state != CrashballState.Gaming) return;
		arena_state = CrashballState.Ending
		countdown_start = null // prevent scoreboard from showing negative times

		// Determine winner(s) of this arena
		local survivors = players.filter(@(i, p) p && p.IsValid() && p.IsAlive())

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
		local winner_indices = []
		foreach (winner in winners)
		{
			winner_indices.append(players.find(winner))
		}

		winner_indices = winner_indices.filter(@(i, index) index != null)

		foreach(i, player in players)
		{
			if (winner_indices.find(i) != null) continue;

			SetLaser(i, true)
			SetWall(i, true)
		}

		UpdateScoreboard()

		Ware_CreateTimer(@() this.End(), 1.0)
	}

	function End()
	{
		if (arena_state != CrashballState.Ending) return;
		foreach(i, player in players)
		{
			SetLaser(i, false)
			SetWall(i, false)
		}

		remaining_playercount = Ware_GetAlivePlayers().len()

		arena_state = CrashballState.Finished

		UpdateScoreboard()
	}

	function Cleanup()
	{
		// Remove all balls.
		local entities = []
		foreach(ball in GetAllArenaEnts("ball"))
		{
			entities.append(ball)
		}
		foreach(laser in [
			GetArenaEnt("laser_north_left")
			GetArenaEnt("laser_north_right")
			GetArenaEnt("laser_south_left")
			GetArenaEnt("laser_south_right")
			GetArenaEnt("laser_east_left")
			GetArenaEnt("laser_east_right")
			GetArenaEnt("laser_west_left")
			GetArenaEnt("laser_west_right")
		])
		{
			entities.append(laser)
		}
		foreach (brush in [
			GetArenaEnt("wall_north")
			GetArenaEnt("wall_south")
			GetArenaEnt("wall_east")
			GetArenaEnt("wall_west")
		])
		{
			entities.append(brush)
		}
		entities.append(point_worldtext)

		foreach (ent in entities)
		{
			ent.Kill()
		}

		env_lasers = []
		func_brushes = []
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

	function UpdateScoreboard(text_size = 16, forced_message = null)
	{
		local message = ""
		if(forced_message)
		{
			point_worldtext.AcceptInput("SetTextSize", "" + text_size, null, null)
			point_worldtext.AcceptInput("SetText", forced_message, null, null)
			return
		}
		switch (arena_state)
		{
			case CrashballState.Setup:
				if (round_number == 1)
				{
					message = "DEFEND YOUR GOAL!"
					text_size = 32
				}
				else if (final)
				{
					message = format("%d PLAYERS REMAIN!\nFINAL ROUND!", remaining_playercount)
				}
				else
				{
					message = format("%d PLAYERS REMAIN!\nROUND %d", remaining_playercount, round_number)
				}
				break
			case CrashballState.Gaming:
			case CrashballState.Ending:
				// Show scores for players in this arena.
				message = "LIVES REMAINING:"

				// Show scores in clockwise order from the north during gameplay.
				if (players.len() >= 1) message += "\n" + GetLivesRemainingString(players[0])
				if (players.len() >= 3) message += "\n" + GetLivesRemainingString(players[2])
				if (players.len() >= 2) message += "\n" + GetLivesRemainingString(players[1])
				if (players.len() >= 4) message += "\n" + GetLivesRemainingString(players[3])

				if (countdown_start)
				{
					local time_remaining = floor(countdown_duration + countdown_start - Time())
					local minutes = time_remaining / 60
					local seconds = time_remaining % 60
					message += "\n" + format("%d:%02d", minutes, seconds)
				}

				break
			case CrashballState.Finished:
				// If final, declare the winners.
				if (final)
				{
					local winners = [];
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
						message = format("%s WINS!", name)
					}
					else
					{
						message = "WINNERS:"
						foreach(i, player in winners)
						{
							message += "\n" + GetPropString(player, "m_szNetname")
						}
					}
				}
				else
				{
					local survivors = [];
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
				}
				break
			default:
				return;
		}
		point_worldtext.AcceptInput("SetTextSize", "" + text_size, null, null)
		point_worldtext.AcceptInput("SetText", message, null, null)
	}
}

local CrashballRound = class {
	// REQUIRED
	player_groups = null // Array of arrays of player handles for the players in each arena.

	// OPTIONAL
	round_config = null

	// INTERNAL
	arenas = [] // Array of CrashballArena objects.
	function constructor(table = null)
	{
		round_config = {} // Arena configuration.
		arenas = []

		if (table)
		{
			foreach (key, value in table)
				this[key] = value
		}
	}

	function Setup()
	{
		foreach(index, group in player_groups)
		{
			local arena_config = clone(round_config)

			arena_config.players <- group
			arena_config.index <- index

			local a = CrashballArena(arena_config)

			arenas.append(a)
		}
		foreach(i, arena in arenas)
		{
			printl(format("///////////////////// ARENA %d /////////////////////", i))

			arena.Setup()
		}
	}

	function UpdateScoreboards(text_size = 16, forced_message = null)
	{
		foreach (arena in arenas)
		{
			arena.UpdateScoreboard(text_size, forced_message)
		}
	}

	function Start()
	{
		foreach (arena in arenas)
		{
			arena.Start()
		}
		last_state_change = Time()
		current_state = CrashballState.Gaming
	}

	function Update()
	{
		remaining_playercount = Ware_GetAlivePlayers().len()

		foreach (arena in arenas)
		{
			arena.Update()
		}
	}

	function ForceEnd()
	{
		if (current_state == CrashballState.Gaming)
		{
			last_state_change = Time()
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
		last_state_change = Time()
		current_state = CrashballState.Finished
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
		return true;
	}

	function Cleanup()
	{
		foreach (arena in arenas)
		{
			arena.Cleanup()
		}
		last_state_change = Time()
		current_state = CrashballState.Cleaned
	}
}

// CRASHBALL FUNCTIONS

function StartCrashballRound()
{
	last_state_change = Time()
	current_state = CrashballState.Setup
	round_number++
	local players = Ware_GetAlivePlayers()
	remaining_playercount = players.len()

	if (remaining_playercount <= 1 || final_round)
	{
		// We have a winner!
		foreach(player in players)
		{
			Ware_PassPlayer(player, true)
		}
		Ware_CreateTimer(@() Ware_EndMinigame(), 1.0)
		return
	}

	// Round actually starts here.

	// *theoretically* the game could go on forever if everyone ties in every round.
	// To stop this, absolute_max_rounds is set to 1 above the expected amount of rounds.
	// Realistically 99.9% of games should end in the expected amount of rounds.
	local is_final = (current_round && current_round.final)
		|| players.len() <= max_players_per_arena
		|| round_number >= absolute_max_rounds

	final_round = is_final

    current_round = CrashballRound({
		player_groups = DividePlayersIntoArenas(players)
		round_config = GetRoundConfig(is_final)
	})

	printl("STARTING ROUND")

    current_round.Setup()

	// TODO: Countdown sounds
	Ware_CreateTimer(@() current_round.UpdateScoreboards(32, "3..."), 3.0)
	Ware_CreateTimer(@() current_round.UpdateScoreboards(32, "2..."), 4.0)
	Ware_CreateTimer(@() current_round.UpdateScoreboards(32, "1..."), 5.0)
	Ware_CreateTimer(@() current_round.UpdateScoreboards(32, "GO!"), 6.0)
    // call to current_round.Start() in OnUpdate()
}

// Divide players into arenas.
// Arenas are divided to maximise the number of players in each arena.
// Every arena will always have at least 3 players, unless there are exactly 2 or 5 players.
// Returns array of arrays of player handles.
function DividePlayersIntoArenas(players)
{
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
            ball_limit_increase_times = [0.0, 10.0, 30.0, 60.0, 90.0]
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

function CleanupCrashballRound()
{
	if (!current_round) return
	printl("CLEANING ROUND")
	current_round.Cleanup()
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

function OnTeleport(players)
{
	// do nothing: we handle teleports during the round.
}

function OnStart()
{
	remaining_playercount = Ware_GetAlivePlayers().len()

	local i = remaining_playercount
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
	switch (current_state)
	{
		case CrashballState.Setup:
			if (Time() - last_state_change > 7.0) current_round.Start()
		case CrashballState.Gaming:
			if (!current_round) break
			current_round.Update()
			if(current_round.CheckIfAllArenasFinished()) current_round.End()
			break
		case CrashballState.Finished:
			if(Time() - last_state_change > 3.0) CleanupCrashballRound()
			break
		case CrashballState.Cleaned:
			StartCrashballRound()
			break
	}
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