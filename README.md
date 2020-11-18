What is this?
=============

This is a command-line program that takes a config file of your in-game controls settings, and generates a sequence of mouse and keyboard commands to input them into the game... much faster than you can.

Use cases:

 - You want the same config on multiple accounts
 - You want to change a single keybind but have hero-specific overrides that you have to over-override
 - You prefer editing configs in a text editor instead of a gui
 
### [Watch a demo on youtube here](https://www.youtube.com/watch?v=RsJooMJFu4I)

 
Getting started
===============

Downloading and running the program
-----------------------------------

 - [Download `OWControls.zip` from the releases tab](https://github.com/klasbo/OWControls/releases).  
 - Unzip, and run the program from the command line (`Shift + Right Click` in the folder -> "Open command window here")  
   Example: `.\OWControls.exe -i settings.json`
 - Once loaded, go to Overwatch and open up the Controls tab in the Options menu. Press `F7` to start inputting commands.
 - If something goes wrong, press `BREAK` (the key to the right of Scroll Lock) to abort the input.
 - A beep will sound when all the program is done inputting settings.
 - Press `Ctrl+C` in the command line window to close the program.
 
This program only works in fullscreen (both borderless or exclusive), with a 16:9 aspect ratio and a 16:9 resolution, and on the primary monitor (the one with the windows task bar on it).


### Options:

The only option you should need is the first one (`-i`), used to select the config file.

 - `-i` `--input`:  
    The path to the config file you want to input into the game.  
    *Examples can be found in the [examples](/examples) folder.*
 - `-o` `--options`:  
    The path to the options file that describes what options exist in the game.  
    *By default, this is the last file in the [options](/options) folder, which is the options for the latest patch.*
 - `-t` `--tick`:  
    The delay between two successive inputs sent to the game, in milliseconds (default: 17).  
    *Increase this if your computer can't keep up with the s p e e d.*
 - `-m` `--t_menu`:  
    The delay to wait for the hero-specific menus to load, in milliseconds (default: 800).  
    *Increase this if the program starts scrolling random places after selecting a hero from the drop-down list.*
 - `-s` `--t_scroll`:  
    The delay to wait for the smooth-scroll scroll bar to move one segment, in milliseconds (default: 100).  
    *Increase this if the program doesn't open the hero-specific menus properly.*
 - `-r` `--run`:  
    The hotkey to start inputting commands to the game (default: F7).  
    *This program will yoink all control of this key from the rest of your system. Choose wisely.*
 - `-a` `--abort`:  
    The hotkey to stop inputting commands if something goes wrong (default: BREAK).  
    *Don't use a key that you intend to use as a binding somewhere, because then you will abort the input when you get there.*

 
Creating your own config file
-----------------------------

It is *highly* recommended that you [look at the examples](/examples) and copy-paste. I would suggest starting with the [all settings example](/examples/all_settings.json) if you want to create a full config file, or the [commo rose example](/examples/battlefield_commorose.1.48.json) if you just want to customize the patch 1.48 communication menu.

You can skip this section if you look at the examples.

### Settings file structure

The settings file is a JSON file. The general top-level structure is
```
[
    "string",
    {"heroName" : [
        {"setting1" : value},
        {"setting2" : value},
        ...
    ]},
    {"heroName" : [
        // settings...
    ]}
]
```
The first string elements are optional. The top string options can be either:
 - Comments: strings that start with "//" are ignored
 - Restore defaults command: a string that matches "Restore defaults", "Reset" or "unbindall" (case insensitive) will restore all settings to their defaults before proceeding.
 
Arrays are used to preserve the ordering of the inputs, so that the inputs sent to the game are performed in the order they are written in the file.

### Individual settings syntax

There are 6 different kinds of options in the game. Here is the syntax used for each:

 - Slider:  
    `{"sliderName" : number}`  
    Example: `{"Sensitivity": 3.14}`
    
 - Toggle:
    `{"toggleName" : boolean}`  
    Example `{"Allow backwards wallride" : true}`
    
 - Dropdown:  
    `{"dropdownName" : string}`  
    Example: `{"Reticle type" : "Crosshairs"}`
    
 - Binding:  
    A single binding: `{"bindingName" : string}`  
    Example: `{"Forward" : "w"}`  
      
    Multiple bindings: `{"bindingName" : [string, ...]}`  
    Example: `{"Quick melee": ["mouse 4", "1"]}`  
    
    Bindings with modifier keys: `{"bindingName" : [[string, ...], ...]}`  
    Example: `{"Toggle fps display": [["shift", "control", "r"]]}`  
    
    Example of setting with both modifiers and multiple bindings:  
    `{"Hide chat": ["delete", ["shift", "control", "c"]]}`  
    
 - Commo: *new in patch 1.48*  
    Change just the rose item: `{"rosePosition" : string}`  
    Example: `{"Commo rose NE": "Hello"}`  
    
    Change the rose item and add a binding: `{"rosePosition" : {string : binding}}`  
    (Bindings work as described above)  
    Example: `{"Commo rose S":  {"Ultimate status" : "z"}}`  
    Example: `{"Commo rose S":  {"Ultimate status" : [["alt", "z"]]}}`  (binds to alt+z)  
    
    Change just the binding: `{"rosePosition" : [binding]}`  
    
 - Submenu:
    `{"submenuName" : [settings...]}`  
    Example: 
    ```json
    {"Reticle Advanced": [
        {"Color":     "White"},
        {"Thickness": 1},
    ]}
    ```
    
Setting names are case-sensitive. Bindings are not.

### What is the name of this key?

The list of valid keys to use for bindings is [found in this file](/keycodes.d). If you don't know what the keycode for a key on your keyboard is, use [KeyboardStateView](https://www.nirsoft.net/utils/keyboard_state_view.html).

On the brokenness of menus
==========================

Overwatch's controls menu has two points of jank that make them frustrating as heck: Toggle options don't respect directional input, and hero-specific overrides are just broken.

### Toggle options

If you press the right arrow on a toggle setting that is currently OFF, you will turn it ON. All good so far. If you the press the right arrow again, you will turn it OFF. This is dumb. Because of this, it is impossible to guarantee that modifying a toggle option will set the setting to the desired value, unless you already know what the value was. 

Since this program does not read the screen, it gives you a warning every time you change a toggle option without first resetting all settings to their defaults (via the "Restore defaults" command). However, it does not warn you for putting in the "wrong" boolean (writing `true` to an option that is already ON), because *it is the Overwatch menu that is wrong, not this program*. Hrmpf.

### Hero-specific overrides

Jank number 1: If you change the crosshair color on Ana to green, then there will exist a hero-specific override for that crosshair color. Changing the all-heroes default to red will now not affect Ana. *However*, if you change the all-heroes default to green, then open Ana's menu *but don't change anything*, then change the all-heroes default to red, it will now *also affect Ana*. But if you don't open Ana's menu and back again (that is - just change the all-heroes crosshair to green then red), it does not change Ana's crosshair color. Conclusion: Opening (or is it closing?) a menu can change the internal state of the overrides, and changing an all-hero default can override hero-specific overrides.

Jank number 2: If we do the same test, but it's a keybind instead of crosshair color, then... it doesn't work like that. You cannot over-override to delete a hero-specific keybind-override by setting the all-heroes default binding to the same as the hero-specific binding. Conclusion: Updates to the internal state of overrides depends on what kind of setting it is.

Jank number 3: Setting a hero-specific override to a keybind does not just set the override state for that specific keybind, but *all of the keybinds*. You changed Winston's right click to quick melee? If you change your push to talk key then it won't update for Winston. Conclusion: What in the heckers.

### Bonus: The amount of crosshair options changes

The Dot and Circle crosshair types don't have a crosshair length, so instead of making it possible to scroll to that option but not modify it, Overwatch just skips straight over it when scrolling, thereby changing the number of options. A similar thing applies with the Show Accuracy toggle (which has the double problem of being a toggle option) disabling the Center Gap option.

Because of this, this program will warn you when certain crosshair modifications are *probably* going to do the wrong thing, or *definitely* going do the wrong thing. But it won't stop you from doing the wrong thing.







































