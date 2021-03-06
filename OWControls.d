import core.sys.windows.winbase;
import core.sys.windows.windef;
import core.sys.windows.winuser;
import core.thread;
import std.algorithm;
import std.array;
import std.concurrency;
import std.conv;
import std.datetime.stopwatch;
import std.datetime;
import std.file;
import std.format;
import std.functional;
import std.getopt;
import std.json;
import std.math;
import std.range;
import std.regex;
import std.stdio;
import std.string;

import keycodes;



__gshared uint      tick_ms                 = 17;
__gshared Duration  tick;
__gshared uint      menuLoadTime_ms         = 800;
__gshared Duration  menuLoadTime;
__gshared uint      scrollLoadTime_ms       = 100;
__gshared Duration  scrollLoadTime;

__gshared string    performInputHotkey_str  = "F7";
__gshared ushort    performInputHotkey_vkey;
__gshared string    abortInputHotkey_str    = "BREAK";
__gshared ushort    abortInputHotkey_vkey;


struct Coordinates {
    POINT heroSelect             = POINT(46080, 10240);
    POINT heroMenu               = POINT(46080, 13200);
    POINT optionsScrollBarTop    = POINT(53247, 9250 );
}
auto coords = Coordinates();


struct Options {
    JSONValue           top;
    JSONValue           middle;
    JSONValue           bottom;
    string[]            heroList;
    JSONValue[string]   hero;
}


void main(string[] args){

    string  inputFile;
    string  optionsFile;
    auto sw = std.datetime.stopwatch.StopWatch(AutoStart.no);
    
    // CONFIG
    {
        getopt(args,
            std.getopt.config.required,
            "i|input",          &inputFile,
            "o|options",        &optionsFile,
            "t|tick",           &tick_ms,
            "m|t_m|t_menu",     &menuLoadTime_ms,
            "s|t_s|t_scroll",   &scrollLoadTime_ms,
            "r|run",            &performInputHotkey_str,
            "a|abort",          &abortInputHotkey_str,
        );
        
        tick            = tick_ms.msecs;
        menuLoadTime    = menuLoadTime_ms.msecs;
        scrollLoadTime  = scrollLoadTime_ms.msecs;
        
        void setHotkey(ref ushort keycode, ref string keyname){
            keyname = keyname.toUpper;
            if(keyname != ""){
                assert(keyname in vkeyCodeOf, format("\"%s\" is not a valid key for hotkeys", keyname));
            }
            keycode = vkeyCodeOf[keyname];
        }
        setHotkey(performInputHotkey_vkey,  performInputHotkey_str);
        setHotkey(abortInputHotkey_vkey,    abortInputHotkey_str);
    }
    
    
    // CREATING INPUT SEQUENCE
    
    if(optionsFile == ""){
        optionsFile = dirEntries("options", SpanMode.shallow).array[$-1];
    }
    writefln("Options file: %s", optionsFile);
    
    writeln("Loading...");    
    sw.start();
    
    auto j = optionsFile.readText.parseJSON;
    auto options = Options(
        j["top"],
        j["middle"],
        j["bottom"],
        j["heroList"].array.map!(a => a.str).array,
        j["hero"].object
    );
    
    auto inputs = heroSettingsToActions(inputFile.readText.parseJSON, options);
    
    sw.stop();    
    auto loadTime = sw.peek.split!("msecs", "usecs");
    writefln("Loading complete (t: %d.%03dms)", loadTime.msecs, loadTime.usecs);
    
    auto inputTime = (inputs.length * tick).split!("seconds", "msecs");
    writefln("Inputting settings should take %d.%01d seconds", inputTime.seconds, inputTime.msecs/100);

  
    // RUNNING INPUT SEQUENCE
    
    enum Behavior {
        idle,
        running,
    }
    struct State {
        Behavior    behavior;
        size_t      index;
    }
    auto state = State(Behavior.idle, 0);
    
    auto ticker         = spawn(&ticker_thr);
    auto hotkeyReader   = spawn(&hotkeyReader_thr);
    
    writefln("Press \"%s\" to start inputting commands (%s to abort)",
        performInputHotkey_str == ""    ? "F7"  : performInputHotkey_str,
        abortInputHotkey_str == ""      ? "ESC" : abortInputHotkey_str,
    );
    
    while(true){
        receive(
            (Action a){
                final switch(a) with(Action){
                case PerformInput:
                    final switch(state.behavior) with(Behavior){
                    case idle:
                        writeln("Running input sequence");
                        state.behavior = running;
                        ticker.send(tick);
                        break;
                    case running:
                        break;
                    }
                    break;
                    
                case AbortInput:
                    final switch(state.behavior) with(Behavior){
                    case idle:
                        break;
                    case running:
                        writefln("\7Aborting input sequence (%d of %d inputs performed)", state.index, inputs.length);
                        ticker.send(0.msecs);
                        state.behavior = idle;
                        state.index = 0;
                        break;
                    }
                    break;
                }
            },
            (TimerTick t){
                final switch(state.behavior) with(Behavior){
                case idle:
                    break;
                case running:
                    SendInput(1, &inputs[state.index], INPUT.sizeof);
                    state.index++;
                    if(state.index >= inputs.length){
                        writeln("\7Input sequence completed");
                        ticker.send(0.msecs);
                        state.behavior = idle;
                        state.index = 0;
                    }
                    break;
                }
            }
        );
    }
}

enum Action {
    PerformInput,
    AbortInput,
}
void hotkeyReader_thr(){
    RegisterHotKey(null, Action.PerformInput, 0x4000, performInputHotkey_vkey);
    RegisterHotKey(null, Action.AbortInput,   0x4000, abortInputHotkey_vkey);

    auto msg = MSG();
    while(GetMessage(&msg, null, 0, 0) != 0){
        if(msg.message == WM_HOTKEY){
            ownerTid.send(cast(Action)(msg.wParam));
        }
    }
}

struct TimerTick {}
void ticker_thr(){
    auto wakeTime = Clock.currTime + 1.hours;
    Duration tick;
    bool active;
    
    while(true){
        auto timeout = wakeTime - Clock.currTime;
        auto timedOut = !receiveTimeout(timeout,
            (Duration d){
                if(d == 0.msecs){
                    wakeTime += 1.hours;
                    active = false;
                } else {
                    tick = d;
                    wakeTime = Clock.currTime + tick;
                    active = true;
                }
            },
        );
        if(timedOut){
            if(active){
                ownerTid.send(TimerTick());
                wakeTime += tick;
            } else {
                wakeTime += 1.hours;
            }
        }
    }
}




//--------------------------------------
// OPTIONS : creating OptionInfo[string] from file
//--------------------------------------


enum OptionType {
    Slider,
    Toggle,
    Dropdown,
    Submenu,
    Binding,
    Commo,
}

struct OptionInfo {
    int         idx;
    OptionType  type;
    JSONValue   validRange;
}

alias genOptions = memoize!_genOptions;

OptionInfo[string] _genOptions(JSONValue optionset){
    OptionInfo[string] o;

    assert(optionset.type == JSONType.array,
        "Option set must be an array, to preserve menu ordering");
    foreach(idx, opt; optionset.array){
        switch(opt.type){
        case JSONType.object:
            assert(opt.object.keys.length == 1,
                format("A single option can only contain one object (%s)", opt.object.keys));
            string name = opt.object.keys[0];

            assert(name !in o, format("Option \"%s\" is duplicated (%d and %d)", name, idx, o[name].idx));

            JSONValue validRange = opt.object.values[0];
            switch(validRange.type){
            case JSONType.array:
                assert(validRange.array.length > 0,
                    format("Option \"%s\"'s valid range cannot be an empty array", name));
                switch(validRange.array[0].type){

                case JSONType.object:
// object with {string : array of length n with objects}:               this is a submenu
                    assert(validRange.array.all!(a => a.type == JSONType.object),
                        format("Submenu option \"%s\"'s first valid value is an object, but the rest are not", name));
                    o[name] = OptionInfo(idx, OptionType.Submenu, validRange);
                    break;


                case JSONType.integer, JSONType.float_:
// object with {string : array of length 2 with integers or floats}:    this is a slider
                    assert(validRange.array.length == 2,
                        format("Slider option \"%s\"'s first valid value indicates a slider, which must have only 2 values. Got %d instead (%s)",
                        name, validRange.array.length, validRange));
                    assert(validRange.array[1].type == JSONType.integer || validRange.array[1].type == JSONType.float_,
                        format("Slider option \"%s\"'s first valid value is a number, but the second one is %s", name, validRange.array[1].type));
                    o[name] = OptionInfo(idx, OptionType.Slider, validRange);
                    break;

                case JSONType.string:
// object with {string : array of length n with strings}:               this is a drop-down
                    assert(validRange.array.all!(a => a.type == JSONType.string),
                        format("Drop-down option \"%s\"'s first valid value is a string, but the rest are not", name));
                    o[name] =  OptionInfo(idx, OptionType.Dropdown, validRange);
                    break;

                default: break;
                }
                break;

            case JSONType.string:
                switch(validRange.str){
                case "toggle":
// object with {string : "toggle"}:                                     this is a toggle
                    o[name] = OptionInfo(idx, OptionType.Toggle, validRange);
                    break;
                default: break;
                }
                break;

            case JSONType.object:
// object with {string : {"commo": [string,]}}:                         this is a commo rose
                if("commo" in validRange.object){
                    assert(validRange["commo"].type == JSONType.array && validRange["commo"].array.all!(a => a.type == JSONType.string),
                        format("Commo option \"%s\"'s value range is not an array of strings", name));
                    o[name] = OptionInfo(idx, OptionType.Commo, validRange["commo"]);
                }
                break;

            default:
                assert(0, format("Unrecognized option type in option set: %s (%s)", opt.type, opt.toPrettyString));
            }
            break;

        case JSONType.string:
            string name = opt.str;
            assert(name !in o, format("Option \"%s\" is duplicated (%d and %d)", name, idx, o[name].idx));
            
// just string:     this is a binding
            o[name] = OptionInfo(idx, OptionType.Binding, JSONValue(null));
            break;

        default:
            assert(0, format("Unrecognized option type in option set: %s (%s)", opt.type, opt.toPrettyString));
        }
    }

    return o;
}



//--------------------------------------
// SETTINGS : creating INPUT[] from file
//--------------------------------------


INPUT[] heroSettingsToActions(JSONValue heroSettings, Options options){

    INPUT[] inputs;
    inputs.reserve(1000);
    int currHeroIdx = -1;
    int optionExitDepth = 150;
    auto optionState = OptionState(options.heroList);

    assert(heroSettings.type == JSONType.array,
        format("Settings top-level container must be an array (to preserve ordering of inputs), got %s", heroSettings.type));
    assert(heroSettings.array.length > 0,
        format("Settings array is empty"));
     
    // strings
    foreach(v; heroSettings.array){
        if(v.type == JSONType.string){
            string str = v.str;
            if(["RESET DEFAULTS", "RESET", "RESTORE DEFAULTS", "RESTORE", "DEFAULT", "UNBINDALL"].canFind(str.toUpper)){
                inputs.inputVKey(VK_BACK);
                inputs.inputVKey(VK_RETURN);
                heroSettings.array = heroSettings.array[1..$];
                optionState.restoreDefaults();
            } else if(str.startsWith("//")){
                writefln("\t\"%s\"", str);
                heroSettings.array = heroSettings.array[1..$];
            } else {
                assert(0, format("Unrecognized string \"%s\", did you mean \"Restore defaults\"?", heroSettings.array[0].str));
            }
        } else {
            break;
        }
    }

        
    // objects
    foreach(heroSettingIdx, heroSetting; heroSettings.array){
    
        assert(heroSetting.type == JSONType.object  &&  heroSetting.object.length == 1,
            format("Per-hero settings must be a single object of the form '\"heroName\" : [settingsArray]'"));

        foreach(heroName, settings; heroSetting.object){
            assert(options.heroList.canFind(heroName.toLower),
                format("Hero \"%s\" not found (valid heroes: %s)", heroName, options.heroList));
            assert(settings.type == JSONType.array,
                format("Hero settings must be an array (to preserve ordering of inputs), got %s (item %d: hero name \"%s\")", settings.type, heroSettingIdx, heroName));
            assert(settings.array.all!(a => a.type == JSONType.object),
                format("Hero settings items must be objects of the form '{\"settingName\" : settingValue}' (item %d: hero name \"%s\")", heroSettingIdx, heroName));


            currHeroIdx = inputs.inputHeroSelect(heroName, options.heroList, currHeroIdx, optionExitDepth);

            OptionInfo[string] optionInfos = (heroName == options.heroList[0]) ?
                (options.top ~ options.middle ~ options.hero[heroName] ~ options.bottom).genOptions :
                (options.top ~ options.hero[heroName] ~ options.middle ~ options.bottom).genOptions;
                
            optionState.currHero = heroName;
            optionExitDepth = inputs.settingsToActions(settings, optionInfos, optionState);
        }
    }

    return inputs;
}


int settingsToActions(ref INPUT[] inputs, JSONValue heroSettings, OptionInfo[string] options, ref OptionState optionState){

    int currentOptionIdx = 0;

    foreach(setting; heroSettings.array){
        assert(setting.type == JSONType.object);
        assert(setting.object.length == 1);
        string      settingName     = setting.object.keys[0];
        JSONValue   settingValue    = setting.object.values[0];
        
        
        assert(settingName in options,
            format("Setting \"%s\" not found in options", settingName));

        auto optionInfo = options[settingName];

        // move to option
        if(optionInfo.idx < currentOptionIdx){
            inputs.inputVKey(VK_UP, currentOptionIdx - optionInfo.idx);
        } else if(optionInfo.idx > currentOptionIdx){
            inputs.inputVKey(VK_DOWN, optionInfo.idx - currentOptionIdx);
        }
        currentOptionIdx = optionInfo.idx;

        final switch(optionInfo.type) with(OptionType){
        case Slider:
            // validate
            switch(optionInfo.validRange.array[0].type){
            case JSONType.integer:
                assert(settingValue.type == JSONType.integer,
                    format("%s: Slider value must be an integer, got %s (%s)", settingName, settingValue, settingValue.type));
                long min = optionInfo.validRange.array[0].integer;
                long max = optionInfo.validRange.array[1].integer;
                long val = settingValue.integer;
                assert(min <= val && val <= max,
                    format("Setting \"%s\": Slider value %d is outside the valid range (%d, %d)", settingName, val, min, max));
                break;
            case JSONType.float_:
                assert(settingValue.type == JSONType.integer || settingValue.type == JSONType.float_,
                    format("Setting \"%s\": Slider value must be a number, got %s (%s)", settingName, settingValue, settingValue.type));
                double min = optionInfo.validRange.array[0].get!double;
                double max = optionInfo.validRange.array[1].get!double;
                double val = settingValue.get!double;
                assert(min <= val && val <= max,
                    format("Setting \"%s\": Slider value %f is outside the valid range (%f, %f)", settingName, val, min, max));
                break;
            default:
                break;
            }

            // generate input
            string sequence = (optionInfo.validRange.array[0].type == JSONType.integer) ?
                settingValue.integer.to!string :
                format("%.2f", settingValue.get!double);
            foreach(ch; sequence){
                inputs.inputVKey(ch == '.' ? VK_OEM_PERIOD : cast(ushort)ch);
            }
            inputs.inputVKey(VK_RETURN);
            break;

        case Toggle:
            // validate
            assert(settingValue.type == JSONType.true_ || settingValue.type == JSONType.false_,
                format("Setting \"%s\": must be either true or false, got \"%s\" (%s)", settingName, settingValue, settingValue.type));

            // generate input
            inputs.inputVKey(settingValue.boolean ? VK_RIGHT : VK_LEFT);
            break;

        case Dropdown:
            inputs.inputDropdown(settingName, settingValue, optionInfo);
            break;

        case Submenu:
            // (validation occurs in recursion)
            // generate input
            inputs.inputVKey(VK_SPACE);
            inputs.inputVKey(VK_DOWN);
            int suboption = settingsToActions(inputs, settingValue, genOptions(options[settingName].validRange), optionState);
            inputs.inputVKey(VK_UP, suboption+1);
            inputs.inputVKey(VK_SPACE);
            break;


        case Binding:
            inputs.inputBinding(settingName, settingValue, optionInfo);
            break;

        case Commo:
            string[] commoOptions = optionInfo.validRange.array.map!(a => a.str).array;

            switch(settingValue.type){
            case JSONType.string:
            // string: "selection"              -> just selection from dropdown (no binding)
                string comm = settingValue.str;
                assert(commoOptions.canFind(comm),
                    format("Commo rose message setting \"%s\": must be one of %s, got \"%s\"", settingName, commoOptions, comm));

                inputs.inputVKey(VK_LEFT, 3);
                inputs.inputDropdown(settingName, settingValue, optionInfo);
                inputs.inputVKey(VK_RIGHT, 3);
                break;

            case JSONType.object:
            // object: {selection : binding}    -> selection from dropdown, then binding
                assert(settingValue.object.length == 1,
                    format("Commo rose message-and-binding setting \"%s\": object must be a single '{\"message\" : binding...}' pair)", settingName));
                string comm = settingValue.object.keys[0];
                assert(commoOptions.canFind(comm),
                    format("Commo rose message-and-binding setting \"%s\": message must be one of %s, got \"%s\"", settingName, commoOptions, comm));

                inputs.inputVKey(VK_LEFT, 3);
                inputs.inputDropdown(settingName, JSONValue(comm), optionInfo);
                inputs.inputVKey(VK_RIGHT, 3);
                inputs.inputBinding(settingName, settingValue.object[comm], optionInfo);
                break;

            case JSONType.array:
            // array:  [binding...]             -> just binding
                inputs.inputBinding(settingName, settingValue, optionInfo);
                break;

            default: break;
            }
            break;
        }
                
        badSettingCheck(optionState, settingName, settingValue, options);
    }
    return currentOptionIdx;
}


//--------------------------------------
// INPUT[] HELPERS
//--------------------------------------


void inputBinding(ref INPUT[] inputs, string settingName, JSONValue settingValue, OptionInfo optionInfo){
    // convert all to same format (2-long array of [string | array-of-string])
    //   by converting single string to ["str", ""]
    if(settingValue.type == JSONType.string){
        settingValue = [settingValue.str, ""];
    }

    foreach(col, binding; settingValue.array){
        // validate
        assert(binding.type == JSONType.string || (binding.type == JSONType.array && binding.array.all!(a => a.type == JSONType.string)),
            format("Setting \"%s\": Bindings must be either a single string, or an array of strings", settingName));
        bool inputRequired =
            (binding.type == JSONType.string && binding.str != "") ||
            (binding.type == JSONType.array);

        // generate input
        if(inputRequired){
            inputs.inputVKey(VK_LEFT, 2-col);
            inputs.inputVKey(VK_SPACE);
            switch(binding.type){
            case JSONType.string:   inputs.inputKeyBind(binding.str);                                   break;
            case JSONType.array:    inputs.inputModifierKeyBind(binding.array.map!(a => a.str).array);  break;
            default: assert(0);
            }
            inputs.inputVKey(VK_RIGHT, 2-col);
        }
    }
}

void inputDropdown(ref INPUT[] inputs, string settingName, JSONValue settingValue, OptionInfo optionInfo){

    // validate
    string[] menuItems = optionInfo.validRange.array.map!(a => a.str).array;
    assert(settingValue.type == JSONType.string && menuItems.canFind(settingValue.str),
        format("Setting \"%s\": must be one of %s, got \"%s\"", settingName, menuItems, settingValue));

    // generate input
    inputs.inputVKey(VK_SPACE);
    inputs.inputVKey(VK_UP, menuItems.length);
    inputs.inputVKey(VK_DOWN, menuItems.countUntil(settingValue.str));
    inputs.inputVKey(VK_SPACE);
}



int inputHeroSelect(ref INPUT[] inputs, string hero, string[] heroList, int fromHeroIdx = -1, int fromOptionDepth = 150){

    int heroIdx = heroList.countUntil(hero);

    // Scroll to top of options screen
    for(int i = 0; i < fromOptionDepth/14 + 1; i++){
        inputs.inputClickOn(coords.optionsScrollBarTop);
        inputs.inputNop((scrollLoadTime/tick + 1).to!uint);
    }
    inputs.inputScroll(2);
    inputs.inputNop((scrollLoadTime/tick + 1).to!uint);

    // Move selection to requested hero
    inputs.inputClickOn(coords.heroSelect);
    inputs.inputMove(coords.heroMenu);
    if(fromHeroIdx == -1){
        inputs.inputVKey(VK_UP, heroList.length);
        inputs.inputVKey(VK_DOWN, heroIdx);
    } else {
        if(heroIdx < fromHeroIdx){
            inputs.inputVKey(VK_UP, fromHeroIdx - heroIdx);
        } else if(heroIdx > fromHeroIdx){
            inputs.inputVKey(VK_DOWN, heroIdx - fromHeroIdx);
        }
    }

    // Select hero, wait for menu to load
    inputs.inputVKey(VK_SPACE);
    inputs.inputNop((menuLoadTime/tick + 1).to!uint);
    inputs.inputVKey(VK_DOWN);
    return heroIdx;
}



void inputNop(ref INPUT[] inputs, uint count){
    for(uint i = 0; i < count; i++){
        inputs ~= INPUT(INPUT_MOUSE, MOUSEINPUT(0, 0, 0, 0, 0, 0));
    }
}

void inputMove(ref INPUT[] inputs, POINT p){
    inputs ~= INPUT(INPUT_MOUSE, MOUSEINPUT(p.x, p.y, 0, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE, 0, 0));
}

void inputClickOn(ref INPUT[] inputs, POINT p){
    inputs.inputMove(p);
    inputs ~= INPUT(INPUT_MOUSE, MOUSEINPUT(0, 0, 0, MOUSEEVENTF_LEFTDOWN, 0, 0));
    inputs ~= INPUT(INPUT_MOUSE, MOUSEINPUT(0, 0, 0, MOUSEEVENTF_LEFTUP, 0, 0));
}

void inputScroll(ref INPUT[] inputs, int n){
    // n>0 : up   |   n<0 : down
    INPUT input;
    int dir     = (n>0) ? 1 : -1;
    int count   = abs(n);
    for(int i = 0; i < count; i++){
        inputs ~= INPUT(INPUT_MOUSE, MOUSEINPUT(0, 0, dir, MOUSEEVENTF_WHEEL, 0, 0));
    }
}

void inputVKey(ref INPUT[] inputs, ushort vk, uint repeat = 1){
    for(uint i = 0; i < repeat; i++){
        inputs ~= INPUTk(KEYBDINPUT(vk, 0, 0, 0, 0));
        inputs ~= INPUTk(KEYBDINPUT(vk, 0, KEYEVENTF_KEYUP, 0, 0));
    }
}

void inputKeyBind(ref INPUT[] inputs, string binding){
    string b = binding.toUpper;
    if(b in vkeyCodeOf){
        inputs.inputVKey(vkeyCodeOf[b]);
    } else if(b in inputOf){
        inputs ~= inputOf[b];
    } else {
        assert(false, format("Unrecognized keybind input: \"%s\"", binding));
    }
}


void inputModifierKeyBind(ref INPUT[] inputs, string[] sequence){
    ushort[string] modifiers = [
        "SHIFT"                 : VK_SHIFT,
        "CONTROL"               : VK_CONTROL,
        "MENU"                  : VK_MENU,
        "ALT"                   : VK_MENU,
    ];

    if(sequence.length == 1){
        inputs.inputKeyBind(sequence[0]);
    } else {
        string b = sequence[0].toUpper;
        assert(b in modifiers,
            format("binding modifiers must be \"shift\", \"control\", or \"alt\", got %s", b));
        inputs ~= INPUTk(KEYBDINPUT(modifiers[b], 0, 0, 0, 0));
        inputModifierKeyBind(inputs, sequence[1..$]);
        inputs ~= INPUTk(KEYBDINPUT(modifiers[b], 0, KEYEVENTF_KEYUP, 0, 0));
    }
}

// workaround for lack of union literals
INPUT INPUTk(KEYBDINPUT ki){
    INPUT input;
    input.type = INPUT_KEYBOARD;
    input.ki = ki;
    return input;
}



//--------------------------------------
// BAD SETTING DETECTION
//--------------------------------------


enum OptionAvailable {
    no,
    yes,
    unknown,
}

struct OptionState {
    
    string                      currHero;
    OptionAvailable[string]     crosshairLengthAvailable;
    OptionAvailable[string]     centerGapAvailable;
    bool                        restoredDefaults;
    
    this(string[] heroList){
        currHero = heroList[0];
        foreach(hero; heroList){
            crosshairLengthAvailable[hero]  = OptionAvailable.unknown;
            centerGapAvailable[hero]        = OptionAvailable.unknown;
        }
    }
}

void restoreDefaults(ref OptionState os){
    os.currHero = "all heroes";
    os.restoredDefaults = true;
    foreach(ref v; os.crosshairLengthAvailable){
        v = OptionAvailable.yes;
    }
    foreach(ref v; os.centerGapAvailable){
        v = OptionAvailable.no;
    }
}

void badSettingCheck(ref OptionState os, string settingName, JSONValue settingValue, OptionInfo[string] options){
    /*
    Settings changes can be made in the allheroes or the hero-specific override menu
    Changes can make the hero override the same as - or different from - the allheroes setting
    Changes in the allheroes menu change settings in hero overrides when the values were the same
        (changes are only registered when the menu is closed (another menu opened))
    In other words: changes in the allheroes menu can "override hero overrides" if they started with the same value
    
    Greyed-out settings:
        Some settings can grey-out options, and we want to disallow attempts to change these        
        - Errors are issued if the values of these settings are known to be bad
        - Warnings are issued if the values of these settings are unknown
        Greyed-out options will change the amount of scrolling needed to reach the options below them
            The easiest way to deal with this is to issue the same errors/warnings
            (Easier, because otherwise it requires a two-way dependence between 
                a) knowing the where the options are, and b) knowing what settings have been changed)
            
    Toggle-type settings:
        Changing toggle settings can have unknown effects, since 
            a) there is no way to control the difference between enabling and disabling a setting
            b) there is no way to know what the existing value is, unless all settings are reset to defaults
        The only changes that have known effects are when 
            1) settings have been reset to defaults, and
            2) the toggle is flipped only when it is something other than the default, and
            3) the toggle has been flipped only once
        To guarantee the desired effect of a toggle change, the decision must be based on
            1) if all settings have been reverted to defaults
            2) the current state of the setting (how many times this setting has been toggled)
            3) changes to allheroes overriding of hero-overrides (when the value of the toggles match)
        Again, fixing this requires a two-way dependency between
            a) knowing what the current setting value is, and b) knowing the decision to flip the toggle
        Since the correct solution is to fix the input (control) end to know what the outcome of changing the setting will be,
            the only case it makes sense to put in the effort to check for is when changing toggles without having reset to defaults,
            especially when considering that the two major use cases for the program are full settings and overriding keybindings.
        - Warnings are issued when toggles are being used without having reset all settings to defaults
    */

    // (consts)
    string[] noCrosshairLengthReticles = ["Circle", "Dot"];
    
    
    // Update what options are grey
    
    void setGreyState(string name, ref OptionAvailable[string] opt, lazy bool cond){
        if(settingName == name){
            auto avail = cond ? OptionAvailable.no : OptionAvailable.yes;
            if(os.currHero == "all heroes"){
                // changes to "all heroes" changes all non-overridden heroes too
                foreach(k, ref v; opt){
                    if(k != "all heroes" && opt["all heroes"] == v){
                        v = avail;
                    }
                }            
            }
            opt[os.currHero] = avail;
        }
    }
    
    setGreyState("Reticle type",  os.crosshairLengthAvailable, noCrosshairLengthReticles.canFind(settingValue.str));
    setGreyState("Show Accuracy", os.centerGapAvailable,       settingValue.boolean);
    

    
    // Check if setting tries to modify grey option (or occluded-by-brey option)

    string greyOption = "Crosshair length";
    if(greyOption in options  &&  options[settingName].idx >= options[greyOption].idx){
        final switch(os.crosshairLengthAvailable[os.currHero]) with(OptionAvailable){
        case no:
            writefln(
                "ERROR:\n" ~ 
                "  Hero \"%s\":\n" ~ 
                "    Option \"%s\" is unavailable since the option \"%s\" is greyed out.\n" ~ 
                "    Reason: Option \"Reticle type\" was set to one of %s.\n" ~ 
                "    Solution: \n" ~ 
                "      Set the reticle type only after changing this setting.\n" ~ 
                "      If you want to set the reticle type to one of %s, set it \n" ~ 
                "      to \"Default\" before changing this setting, then to the desired type after.\n",
                os.currHero, settingName, greyOption, noCrosshairLengthReticles, noCrosshairLengthReticles);
            break;
        case unknown:
            writefln(
                "WARNING:\n" ~ 
                "  Hero \"%s\":\n" ~ 
                "    Option \"%s\" might be unavailable since the option \"%s\" might be greyed out.\n" ~ 
                "    Reason:\n" ~ 
                "      This hero might have hero-specific overrides.\n" ~ 
                "    Solution:\n" ~ 
                "      Assign a value to the option \"Reticle type\" to this hero before changing this setting.\n", 
                os.currHero, settingName, greyOption);
            break;
        case yes:
            // (setting is available => no warnings)
            break;
        }
    }
    
    greyOption = "Center gap";
    if(greyOption in options  &&  options[settingName].idx >= options[greyOption].idx){
        final switch(os.centerGapAvailable[os.currHero]) with(OptionAvailable){
        case no:
            writefln(
                "ERROR:\n" ~ 
                "  Hero \"%s\":\n" ~ 
                "    Option \"%s\" is unavailable since the option \"%s\" is greyed out.\n" ~ 
                "    Reason: Option \"Show accuracy\" was enabled.\n" ~ 
                "    Solution: \n" ~ 
                "      Disable \"Show accuracy\" before changing this setting, then re-enable it after, if desired.\n" ~ 
                "      Note: Resetting to default settings enables \"Show accuracy\" for all heroes\n",
                os.currHero, settingName, greyOption);
            break;
        case unknown:
            writefln(
                "WARNING:\n" ~ 
                "  Hero \"%s\":\n" ~ 
                "    Option \"%s\" might be unavailable since the option \"%s\" might be greyed out.\n" ~ 
                "    Reason:\n" ~                 
                "      This hero might have a hero-specific override for \"Show accuracy\".\n" ~ 
                "    Solution: \n" ~ 
                "      Only use this setting after having reset to default settings.\n",
                os.currHero, settingName, greyOption);
            break;
        case yes:
            // (setting is available => no warnings)
            break;
        }
    }
    
    if(options[settingName].type == OptionType.Toggle){
        if(!os.restoredDefaults){
            writefln(
                "WARNING:\n"~
                "  Hero \"%s\":\n" ~
                "    Toggle option \"%s\" used without resetting to defaults\n",
                os.currHero, settingName
            );
        }
    }
}


//--------------------------------------
// UTILS
//--------------------------------------

JSONValue parseJSON(string s){
    JSONValue v;
    try {
        v = std.json.parseJSON(s);
    } catch(Exception e){
        string msg;
        auto matches = e.msg.matchFirst(r"^.+?Line (\d+?):(\d+?)\)");
        if(matches.length == 3){
            auto line = matches[1].to!int;
            auto col  = matches[2].to!int;
            msg = format("%s\n%s\n%s%s\n", 
                e.msg,
                s.splitLines[line-1],
                " ".repeat(col-1).reduce!"a~b", "^");
        } else {
            msg = e.msg;
        }
        throw new Exception(msg);
    }
    return v;
}

void printInputs(INPUT[] inputs){
    foreach(idx, input; inputs){
        switch(input.type){
        case INPUT_MOUSE:
            writefln("%4d : mouse: %s", idx, input.mi);
            break;

        case INPUT_KEYBOARD:
            //if(input.ki.dwFlags == 0){
                char[40] str;
                GetKeyNameTextA(MapVirtualKeyW(input.ki.wVk, MAPVK_VK_TO_VSC) << 16, str.ptr, str.sizeof);
                writefln("%4d : keybd: %s %s", idx, str, input.ki.dwFlags);
            //}
            break;

        case INPUT_HARDWARE:
            break;
        default: break;
        }
    }
}

POINT cursorPos(){
    POINT p;
    GetCursorPos(&p);
    return p;
}











