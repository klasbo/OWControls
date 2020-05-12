/*


Options:
    All of the things that exist in the menu
    Have names, and a range of valid values
    Have different types
Settings/Preferences:
    The things that exist in your config file
    Have the same names, and a single (desired) value
    Do not need to cover all the options
*/







import core.sys.windows.winbase;
import core.sys.windows.windef;
import core.sys.windows.winuser;
import core.thread;
import std.algorithm;
import std.array;
import std.concurrency;
import std.conv;
import std.datetime.stopwatch;
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





auto tick           = 17.msecs;
auto menuLoadTime   = 800.msecs;
auto scrollLoadTime = 100.msecs;

enum Hotkey {
    HK1,
    HK2,
    HK3,
}


auto heroSelect             = POINT(46080, 10240);
auto heroMenu               = POINT(46080, 13200);
auto optionsMenu            = POINT(20500, 31850);
auto optionsTop             = POINT(15350, 15930);
auto optionsScrollBarTop    = POINT(53247, 9103 );

struct Options {
    JSONValue           top;
    JSONValue           middle;
    JSONValue           bottom;
    string[]            heroList;
    JSONValue[string]   hero;
}

void main(string[] args){

    string inputFile;
    auto sw = StopWatch(AutoStart.no);

    getopt(args,
        std.getopt.config.required,
        "i|input", &inputFile,
    );

    RegisterHotKey(null, Hotkey.HK1, 0x4000, VK_F6);
    RegisterHotKey(null, Hotkey.HK2, 0x4000, VK_F7);
    RegisterHotKey(null, Hotkey.HK3, 0x4000, VK_F8);
    
    writeln("started");
    
    sw.start();
    
    auto j = "options.json".readText.parseJSON;
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

    auto msg = MSG();
    while(GetMessage(&msg, null, 0, 0) != 0){
        if(msg.message == WM_HOTKEY){
            final switch(msg.wParam) with(Hotkey){
            case HK1:
                printInputs(inputs);
                break;
            case HK2:
                performInputs(inputs);
                writeln("\7");
                break;
            case HK3:
                writeln(cursorPos);
                break;
            }
        }
    }
}

// "Reticle advanced"-"Show accuracy" setting makes "center gap" setting unavailable when toggled on.



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



INPUT[] heroSettingsToActions(JSONValue heroSettings, Options options){

    INPUT[] inputs;
    inputs.reserve(1000);
    int currHeroIdx = -1;

    assert(heroSettings.type == JSONType.array,
        format("Settings top-level container must be an array (to preserve ordering of inputs), got %s", heroSettings.type));
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


            currHeroIdx = inputs.inputHeroSelect(heroName, options.heroList, currHeroIdx);

            OptionInfo[string] optionInfos = (heroName == options.heroList[0]) ?
                (options.top ~ options.middle ~ options.hero[heroName] ~ options.bottom).genOptions :
                (options.top ~ options.hero[heroName] ~ options.middle ~ options.bottom).genOptions;

            inputs.settingsToActions(settings, optionInfos);
        }
    }

    return inputs;
}


int settingsToActions(ref INPUT[] inputs, JSONValue heroSettings, OptionInfo[string] options){

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
            int suboption = settingsToActions(inputs, settingValue, genOptions(options[settingName].validRange));
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
    }
    return currentOptionIdx;
}

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



int inputHeroSelect(ref INPUT[] inputs, string hero, string[] heroList, int fromHeroIdx = -1){

    int heroIdx = heroList.countUntil(hero);

    // Scroll to top of options screen
    for(int i = 0; i < 12; i++){
        inputs.inputClickOn(optionsScrollBarTop);
        inputs.inputNop((scrollLoadTime/tick + 1).to!uint);
    }
    inputs.inputScroll(2);
    inputs.inputNop((scrollLoadTime/tick + 1).to!uint);

    // Move selection to requested hero
    inputs.inputClickOn(heroSelect);
    inputs.inputMove(heroMenu);
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

void performInputs(INPUT[] inputs){
    foreach(idx, input; inputs){
        SendInput(1, &input, input.sizeof);
        Thread.sleep(tick);
    }
}




POINT cursorPos(){
    POINT p;
    GetCursorPos(&p);
    return p;
}









ushort[string] vkeyCodeOf;
INPUT[][string] inputOf;
static this(){
    vkeyCodeOf = [
        "LBUTTON"               : VK_LBUTTON,
        "RBUTTON"               : VK_RBUTTON,
        "CANCEL"                : VK_CANCEL,
        "MBUTTON"               : VK_MBUTTON,
        "XBUTTON1"              : VK_XBUTTON1,
        "XBUTTON2"              : VK_XBUTTON2,
        "BACK"                  : VK_BACK,
        "TAB"                   : VK_TAB,
        "CLEAR"                 : VK_CLEAR,
        "RETURN"                : VK_RETURN,
        "ENTER"                 : VK_RETURN,
        "SHIFT"                 : VK_SHIFT,
        "CONTROL"               : VK_CONTROL,
        "ALT"                   : VK_MENU,
        "MENU"                  : VK_MENU,
        "PAUSE"                 : VK_PAUSE,
        "CAPITAL"               : VK_CAPITAL,
        "KANA"                  : VK_KANA,
        "HANGEUL"               : VK_HANGEUL,
        "HANGUL"                : VK_HANGUL,
        "JUNJA"                 : VK_JUNJA,
        "FINAL"                 : VK_FINAL,
        "HANJA"                 : VK_HANJA,
        "KANJI"                 : VK_KANJI,
        "ESCAPE"                : VK_ESCAPE,
        "CONVERT"               : VK_CONVERT,
        "NONCONVERT"            : VK_NONCONVERT,
        "ACCEPT"                : VK_ACCEPT,
        "MODECHANGE"            : VK_MODECHANGE,
        "SPACE"                 : VK_SPACE,
        "PRIOR"                 : VK_PRIOR,
        "PGUP"                  : VK_PRIOR,
        "NEXT"                  : VK_NEXT,
        "PGDN"                  : VK_NEXT,
        "END"                   : VK_END,
        "HOME"                  : VK_HOME,
        "LEFT"                  : VK_LEFT,
        "UP"                    : VK_UP,
        "RIGHT"                 : VK_RIGHT,
        "DOWN"                  : VK_DOWN,
        "SELECT"                : VK_SELECT,
        "PRINT"                 : VK_PRINT,
        "EXECUTE"               : VK_EXECUTE,
        "SNAPSHOT"              : VK_SNAPSHOT,
        "PRINTSCREEN"           : VK_SNAPSHOT,
        "INSERT"                : VK_INSERT,
        "DELETE"                : VK_DELETE,
        "HELP"                  : VK_HELP,
        //"LWIN"                  : VK_LWIN,
        //"RWIN"                  : VK_RWIN,
        "APPS"                  : VK_APPS,
        "NUMPAD0"               : VK_NUMPAD0,
        "NUMPAD1"               : VK_NUMPAD1,
        "NUMPAD2"               : VK_NUMPAD2,
        "NUMPAD3"               : VK_NUMPAD3,
        "NUMPAD4"               : VK_NUMPAD4,
        "NUMPAD5"               : VK_NUMPAD5,
        "NUMPAD6"               : VK_NUMPAD6,
        "NUMPAD7"               : VK_NUMPAD7,
        "NUMPAD8"               : VK_NUMPAD8,
        "NUMPAD9"               : VK_NUMPAD9,
        "MULTIPLY"              : VK_MULTIPLY,
        "ADD"                   : VK_ADD,
        "SEPARATOR"             : VK_SEPARATOR,
        "SUBTRACT"              : VK_SUBTRACT,
        "DECIMAL"               : VK_DECIMAL,
        "DIVIDE"                : VK_DIVIDE,
        "F1"                    : VK_F1,
        "F2"                    : VK_F2,
        "F3"                    : VK_F3,
        "F4"                    : VK_F4,
        "F5"                    : VK_F5,
        "F6"                    : VK_F6,
        "F7"                    : VK_F7,
        "F8"                    : VK_F8,
        "F9"                    : VK_F9,
        "F10"                   : VK_F10,
        "F11"                   : VK_F11,
        "F12"                   : VK_F12,
        "F13"                   : VK_F13,
        "F14"                   : VK_F14,
        "F15"                   : VK_F15,
        "F16"                   : VK_F16,
        "F17"                   : VK_F17,
        "F18"                   : VK_F18,
        "F19"                   : VK_F19,
        "F20"                   : VK_F20,
        "F21"                   : VK_F21,
        "F22"                   : VK_F22,
        "F23"                   : VK_F23,
        "F24"                   : VK_F24,
        "NUMLOCK"               : VK_NUMLOCK,
        "SCROLL"                : VK_SCROLL,
        "LSHIFT"                : VK_LSHIFT,
        //"RSHIFT"                : VK_RSHIFT, // requires scancode to work properly, see inputOf map below
        "LCONTROL"              : VK_LCONTROL,
        "RCONTROL"              : VK_RCONTROL,
        "LALT"                  : VK_LMENU,
        "RALT"                  : VK_RMENU,
        "LMENU"                 : VK_LMENU,
        "RMENU"                 : VK_RMENU,
        //"BROWSER_BACK"          : VK_BROWSER_BACK,
        //"BROWSER_FORWARD"       : VK_BROWSER_FORWARD,
        //"BROWSER_REFRESH"       : VK_BROWSER_REFRESH,
        //"BROWSER_STOP"          : VK_BROWSER_STOP,
        //"BROWSER_SEARCH"        : VK_BROWSER_SEARCH,
        //"BROWSER_FAVORITES"     : VK_BROWSER_FAVORITES,
        //"BROWSER_HOME"          : VK_BROWSER_HOME,
        //"VOLUME_MUTE"           : VK_VOLUME_MUTE,
        //"VOLUME_DOWN"           : VK_VOLUME_DOWN,
        //"VOLUME_UP"             : VK_VOLUME_UP,
        //"MEDIA_NEXT_TRACK"      : VK_MEDIA_NEXT_TRACK,
        //"MEDIA_PREV_TRACK"      : VK_MEDIA_PREV_TRACK,
        //"MEDIA_STOP"            : VK_MEDIA_STOP,
        //"MEDIA_PLAY_PAUSE"      : VK_MEDIA_PLAY_PAUSE,
        "LAUNCH_MAIL"           : VK_LAUNCH_MAIL,
        "LAUNCH_MEDIA_SELECT"   : VK_LAUNCH_MEDIA_SELECT,
        "LAUNCH_APP1"           : VK_LAUNCH_APP1,
        "LAUNCH_APP2"           : VK_LAUNCH_APP2,
        "OEM_1"                 : VK_OEM_1,
        "OEM_PLUS"              : VK_OEM_PLUS,
        "OEM_COMMA"             : VK_OEM_COMMA,
        "OEM_MINUS"             : VK_OEM_MINUS,
        "OEM_PERIOD"            : VK_OEM_PERIOD,
        "OEM_2"                 : VK_OEM_2,
        "OEM_3"                 : VK_OEM_3,
        "OEM_4"                 : VK_OEM_4,
        "OEM_5"                 : VK_OEM_5,
        "OEM_6"                 : VK_OEM_6,
        "OEM_7"                 : VK_OEM_7,
        "OEM_8"                 : VK_OEM_8,
        "OEM_102"               : VK_OEM_102,
        "PROCESSKEY"            : VK_PROCESSKEY,
        //"PACKET"                : VK_PACKET,
        "ATTN"                  : VK_ATTN,
        "CRSEL"                 : VK_CRSEL,
        "EXSEL"                 : VK_EXSEL,
        "EREOF"                 : VK_EREOF,
        "PLAY"                  : VK_PLAY,
        "ZOOM"                  : VK_ZOOM,
        //"NONAME"                : VK_NONAME,
        "PA1"                   : VK_PA1,
        "OEM_CLEAR"             : VK_OEM_CLEAR,
        "0"                     : cast(ushort)'0',
        "1"                     : cast(ushort)'1',
        "2"                     : cast(ushort)'2',
        "3"                     : cast(ushort)'3',
        "4"                     : cast(ushort)'4',
        "5"                     : cast(ushort)'5',
        "6"                     : cast(ushort)'6',
        "7"                     : cast(ushort)'7',
        "8"                     : cast(ushort)'8',
        "9"                     : cast(ushort)'9',
        "A"                     : cast(ushort)'A',
        "B"                     : cast(ushort)'B',
        "C"                     : cast(ushort)'C',
        "D"                     : cast(ushort)'D',
        "E"                     : cast(ushort)'E',
        "F"                     : cast(ushort)'F',
        "G"                     : cast(ushort)'G',
        "H"                     : cast(ushort)'H',
        "I"                     : cast(ushort)'I',
        "J"                     : cast(ushort)'J',
        "K"                     : cast(ushort)'K',
        "L"                     : cast(ushort)'L',
        "M"                     : cast(ushort)'M',
        "N"                     : cast(ushort)'N',
        "O"                     : cast(ushort)'O',
        "P"                     : cast(ushort)'P',
        "Q"                     : cast(ushort)'Q',
        "R"                     : cast(ushort)'R',
        "S"                     : cast(ushort)'S',
        "T"                     : cast(ushort)'T',
        "U"                     : cast(ushort)'U',
        "V"                     : cast(ushort)'V',
        "W"                     : cast(ushort)'W',
        "X"                     : cast(ushort)'X',
        "Y"                     : cast(ushort)'Y',
        "Z"                     : cast(ushort)'Z',
    ];
    inputOf = [
        "MOUSE LEFT CLICK" : [
            INPUT(INPUT_MOUSE, MOUSEINPUT(0, 0, 0, MOUSEEVENTF_LEFTDOWN, 0, 0)),
            INPUT(INPUT_MOUSE, MOUSEINPUT(0, 0, 0, MOUSEEVENTF_LEFTUP, 0, 0))
        ],
        "MOUSE RIGHT CLICK" : [
            INPUT(INPUT_MOUSE, MOUSEINPUT(0, 0, 0, MOUSEEVENTF_RIGHTDOWN, 0, 0)),
            INPUT(INPUT_MOUSE, MOUSEINPUT(0, 0, 0, MOUSEEVENTF_RIGHTUP, 0, 0))
        ],
        "MOUSE MIDDLE CLICK" : [
            INPUT(INPUT_MOUSE, MOUSEINPUT(0, 0, 0, MOUSEEVENTF_MIDDLEDOWN, 0, 0)),
            INPUT(INPUT_MOUSE, MOUSEINPUT(0, 0, 0, MOUSEEVENTF_MIDDLEUP, 0, 0))
        ],
        "MOUSE 4" : [
            INPUT(INPUT_MOUSE, MOUSEINPUT(0, 0, XBUTTON1, MOUSEEVENTF_XDOWN, 0, 0)),
            INPUT(INPUT_MOUSE, MOUSEINPUT(0, 0, XBUTTON1, MOUSEEVENTF_XUP, 0, 0)),
        ],
        "MOUSE 5" : [
            INPUT(INPUT_MOUSE, MOUSEINPUT(0, 0, XBUTTON2, MOUSEEVENTF_XDOWN, 0, 0)),
            INPUT(INPUT_MOUSE, MOUSEINPUT(0, 0, XBUTTON2, MOUSEEVENTF_XUP, 0, 0)),
        ],
        "MOUSE WHEEL UP" : [
            INPUT(INPUT_MOUSE, MOUSEINPUT(0, 0, 1, MOUSEEVENTF_WHEEL, 0)),
        ],
        "MOUSE WHEEL DOWN" : [
            INPUT(INPUT_MOUSE, MOUSEINPUT(0, 0, -1, MOUSEEVENTF_WHEEL, 0)),
        ],
        "MOUSE WHEEL LEFT" : [
            INPUT(INPUT_MOUSE, MOUSEINPUT(0, 0, 1, 0x01000, 0)),
        ],
        "MOUSE WHEEL RIGHT" : [
            INPUT(INPUT_MOUSE, MOUSEINPUT(0, 0, -1, 0x01000, 0)),
        ],
        "RSHIFT": [
            INPUTk(KEYBDINPUT(VK_RSHIFT, 0x36, KEYEVENTF_EXTENDEDKEY, 0, 0)),
            INPUTk(KEYBDINPUT(VK_RSHIFT, 0x36, KEYEVENTF_KEYUP | KEYEVENTF_EXTENDEDKEY, 0, 0)),
        ]


    ];
}
