fs = require 'fs'
os = require 'os'
path = require 'path'
request = require 'superagent'
{ terminal } = require 'terminal-kit'

# -------------------------------------------------------------------------
# EXCEPTIONS
# -------------------------------------------------------------------------

class FailedConfiguration extends Error

# Quit Session exception for easier error and exiting handling
class QuitSession extends Error

# -------------------------------------------------------------------------
# UTILS
# -------------------------------------------------------------------------

print   = terminal
println = (text = '') -> terminal(text + '\n')
readln  = (prompt = '') ->
  print(prompt)

  new Promise (resolve, reject) ->
    terminal.inputField (error, answer) ->
      println()
      if error?
        reject(error)
      else
        resolve(answer)

terminal_width = process.stdin.columns

terminal.on 'key', (name) ->
  process.exit(0) if name == 'CTRL_C'

exists  = (obj, key) -> key of obj and obj[key]

# -------------------------------------------------------------------------
# GAME LOGIC
# -------------------------------------------------------------------------

class AiDungeon
  constructor: ->
    # Initialize variables
    @prompt       = "> "
    @auth_token   = null
    @email        = null
    @password     = null
    @prompt_iter  = null
    @stop_session = false
    @user_id      = null
    @session_id   = null
    @public_id    = null
    @story_config = {}
    @session      = request.agent()

    # Load configuration file
    @load_config()

  load_config: ->
    config_file = "config.json"
    config_file_paths = [
      path.join(path.dirname(__filename), config_file),
      path.join(os.homedir(), ".config", "ai-dungeon", config_file)
    ]
    config = null

    for filename in config_file_paths
      do (filename) ->
        try
          data = fs.readFileSync filename
          config = JSON.parse(data)

    if not config
      print("Missing config file at #{config_file_paths.join(', ')}")
      throw new FailedConfiguration

    if (not exists(config, "auth_token")) and
       (not exists(config, "email")) and
       (not exists(config, "password"))
      throw new FailedConfiguration(
        "Missing or empty authentication configuration.\n
        Please register a token ('auth_token' key)
        or credentials ('email' / 'password')")

    if exists(config, "prompt")
      @prompt = config["prompt"]
    if exists(config, "auth_token")
      @auth_token = config["auth_token"]
    if exists(config, "email")
      @email = config["email"]
    if exists(config, "password")
      @password = config["password"]

  display_splash: ->
    filename = path.resolve(path.dirname(__filename), '..', 'resources')
    locale   = null
    term     = null

    if "LC_ALL" in process.env
      locale = process.env["LC_ALL"]
    if "TERM" in process.env
      term = process.env["TERM"]

    if locale == "C" or (term and term.startsWith("vt"))
      filename = path.join(filename, "opening-ascii.txt")
    else
      filename = path.join(filename, "opening-utf8.txt")

    try
      splash_image = fs.readFileSync(filename)
      println(splash_image)

  login: ->
    try
      response = await @session.post("https://api.aidungeon.io/users")
                               .send({ @email, @password })

      @auth_token = response.body["accessToken"]
      @update_session_auth()

    catch err
      throw new FailedConfiguration(
        "Failed to log in using provided credentials. Check your config."
      )

  update_session_auth: ->
    @session.set("X-Access-Token", @auth_token)

  choose_selection: (allowed_values) ->
    choices = Object.keys(allowed_values)
    items   = ("#{i+1}) #{choice}" for choice, i in choices)

    new Promise (resolve, reject) ->
      terminal.singleColumnMenu items, (error, response) ->
        println()
        if error?
          reject(error)
        else
          resolve(choices[response.selectedIndex])

  make_custom_config: ->
    println(
      "Enter a prompt that describes who you are and the first couple sentences of where you start out ex:\n
      'You are a knight in the kingdom of Larion. You are hunting the evil dragon who has been terrorizing
      the kingdom. You enter the forest searching for the dragon and see'"
    )

    context = await readln(@prompt)

    if context == "/quit"
      throw new QuitSession("/quit")

    @story_configuration =
      storyMode: "custom"
      characterType: null
      name: null
      customPrompt: context
      promptId: null

  choose_config: ->
    # Get the configuration for this session
    response = await @session.get("https://api.aidungeon.io/sessions/*/config")

    if 'modes' of response.body
      modes = response.body["modes"]
      print("Pick a setting...\n")

      selected_mode = await @choose_selection(modes)

      if selected_mode == "/quit"
        throw new QuitSession("/quit")

      # If the custom option was selected load the custom configuration
      if selected_mode == "custom"
        @make_custom_config()

      else
        print("Select a character...\n")

        characters = modes[selected_mode]["characters"]
        selected_character = await @choose_selection(characters)

        if selected_character == "/quit"
          throw new QuitSession("/quit")

        print("Enter your character's name...\n")

        character_name = await readln(@prompt)

        if character_name == "/quit"
          throw new QuitSession("/quit")

        @story_configuration =
          storyMode: selected_mode
          characterType: selected_character
          name: character_name
          customPrompt: null
          promptId: null

  # Initialize story
  init_story: ->
    print("Generating story... Please wait...\n")

    response = await @session.post("https://api.aidungeon.io/sessions")
                             .send(@story_configuration)

    story_response = response.body

    @prompt_iteration = 2
    @user_id    = story_response["userId"]
    @session_id = story_response["id"]
    @public_id  = story_response["publicId"]

    story_pitch = story_response["story"][0]["value"]

    println(story_pitch)

  # Function for when the input typed was ordinary
  process_regular_action: (user_input) ->
    @session.post("https://api.aidungeon.io/sessions/#{@session_id}/inputs")
            .send(text: user_input)
            .then (response) =>
              action_res = response.body

              action_res_str = action_res[@prompt_iteration]["value"]
              println(action_res_str)

  # Function for when /remember is typed
  process_remember_action: (user_input) ->
    @session.patch("https://api.aidungeon.io/sessions/#{@session_id}")
            .send(context: user_input)

  # Function that is called each iteration to process user inputs
  process_next_action: ->
    user_input = await readln(@prompt)

    if user_input == "/quit"
      @stop_session = true

    else
      if user_input.startsWith("/remember")
        await @process_remember_action(user_input["/remember ".length..])
      else
        await @process_regular_action(user_input)
        @prompt_iteration += 2

  start_game: ->
    # Run until /quit is received inside the process_next_action func
    await @process_next_action() until @stop_session

do ->
  try
    # Initialize the AiDungeon class with the given auth_token and prompt
    ai_dungeon = new AiDungeon()

    # Login if necessary
    if not ai_dungeon.auth_token
      await ai_dungeon.login()

    # Clears the console
    terminal.fullscreen()

    # Displays the splash image accordingly
    ai_dungeon.display_splash() if terminal_width >= 80

    # Loads the current session configuration
    await ai_dungeon.choose_config()

    # Initializes the story
    await ai_dungeon.init_story()

    # Starts the game
    ai_dungeon.start_game()

  catch err
    switch err
      when FailedConfiguration
        println(err.message)
        process.exit(1)

      when QuitSession
        println("Bye Bye!")

      # when KeyboardInterrupt
      #   println("Received Keyboard Interrupt. Bye Bye...")

      # when ConnectionError
      #   println("Lost connection to the Ai Dungeon servers")
      #   process.exit(1)

      # when requests.exceptions.TooManyRedirects
      #   println("Exceded max allowed number of HTTP redirects, API backend has probably changed")
      #   exit(1)
      #
      # when requests.exceptions.HTTPError as err
      #   println("Unexpected response from API backend:")
      #   println(err)
      #   exit(1)
      #
      else
       println("Totally unexpected exception:")
       println(err.message)
       process.exit(1)
