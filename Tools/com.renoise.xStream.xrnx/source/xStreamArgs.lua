--[[============================================================================
xStreamArgs
============================================================================]]--
--[[

	This class manages real-time observable values for xStream

  The observable values are exposed as properties of the class itself,
  which means that arguments are restricted from using any of the names
  that are already in use ("model", "args", etc.). 

  While xStreamArg instances are accessed through the .args property, 
  the callback will access the arguments directly as class properties. 

  ## Value transformations

  Accessing values directly as class properties will include a just-in-time
  transformation of the value. For example, if we are listening to the
  index of an instrument, we are likely to use that value for output in
  the pattern. And since the Renoise API uses a one-based counting system,
  it's of great convenience to be able to specify "this is zero-based". 
  
  Possible value-transformations include: 
  + zero_based : count from 0 instead of 1
  + display_as.INTEGER : force integer  


]]

--==============================================================================

class 'xStreamArgs'

xStreamArgs.RESERVED_NAMES = {"Arguments","Presets"}

-------------------------------------------------------------------------------
-- constructor
-- @param xstream (xStream)

function xStreamArgs:__init(model)
  TRACE("xStreamArgs:__init(model)",model)
  
  -- xStreamModel, reference to owner
	self.model = model

  -- table<xStreamArg>
  self.args = {}
  
  -- table<string>
  self._tab_names = {}

  -- table<name={},name={},etc>
  self._linked = {}

  -- table<xStreamArg>
  self.args_observable = renoise.Document.ObservableNumberList()

  -- int, read-only - number of registered arguments
  self.length = property(self.get_length)

  -- int, selected argument (0 = none) 
  self.selected_index = property(self.get_selected_index,self.set_selected_index)
  self.selected_index_observable = renoise.Document.ObservableNumber(0)

  self.selected_arg = property(self.get_selected_arg)

end

-------------------------------------------------------------------------------
-- Get/set methods 
-------------------------------------------------------------------------------

function xStreamArgs:get_length()
  return #self.args
end

-------------------------------------------------------------------------------

function xStreamArgs:get_selected_index()
  return self.selected_index_observable.value
end

function xStreamArgs:set_selected_index(val)
  self.selected_index_observable.value = val
end

-------------------------------------------------------------------------------

function xStreamArgs:get_selected_arg()
  return self.args[self.selected_index_observable.value]
end


--------------------------------------------------------------------------------
-- Class methods
-------------------------------------------------------------------------------
-- Add property to our document, register notifier
-- @param arg (table), see xStreamArg.constructor
-- @param do_replace (bool), do not add getter - it's already defined
-- @return bool, true when accepted
-- @return string, error message (set on failure)

function xStreamArgs:add(arg,index,do_replace)
  TRACE("xStreamArgs:add(arg,index)",arg,index)

  if not arg then
    -- provide default argument
    local str_name = self:get_unique_name()
    --print("str_name",str_name)
    str_name = vPrompt.prompt_for_string(str_name,
      "Enter a name to be used as identifier","Argument Name")
    if not str_name then
      return false
    end
    arg = {
      name = str_name,
      value = 42,
      properties = {
        display_as = xStreamArg.DISPLAYS[xStreamArg.DISPLAY_AS.INTEGER],
        min = 0,
        max = 100,
      },
    }
  end

  -- extract tab name from arg (only one is allowed)
  local match = string.gmatch(arg.name,"[^.]*")
  local count = 0
  local arg_tab_name,arg_name
  for k in match do
    if (k ~= "") then
      count = count+1
      if (count == 1) then
        arg_name = k
        arg_tab_name = k
      elseif (count == 2) then
        arg_name = k
      elseif (count > 2) then
        return false,"Argument name '"..arg.name.."' can only contain one .dot"
      end  
    end
  end
  if (count == 1) then
    arg_tab_name = nil
  end

  --print("arg_tab_name",arg_tab_name)
  --print("arg_name",arg_name)


  -- validate --

  if (type(arg_name)~='string') then
    return false,"Argument name '"..arg_name.."' needs to be a string"
  end
  local is_valid,err = xReflection.is_valid_identifier(arg_name) 
  if not is_valid then
    return false,err
  end

  if arg_tab_name then
    if (type(arg_tab_name)~='string') then
      return false,"Argument tab_name '"..arg_tab_name.."' needs to be a string"
    end
    local is_valid,err = xReflection.is_valid_identifier(arg_tab_name) 
    if not is_valid then
      return false,err
    end
  end

  -- avoid using existing or RESERVED_NAMES
  if not do_replace then
    --print("type(self[arg_name])",type(self[arg_name]))
    --if (type(self[arg_name]) ~= 'nil') or 
    --  (table.find(xStreamArgs.RESERVED_NAMES,arg_name)) 
    local full_name = nil
    if arg.tab_name then
      full_name = arg.tab_name.."."..arg.name
    else
      full_name = arg.name
    end
    --print(">>> full_name",full_name)

    if table.find(self:get_names(),full_name) then
      return false,"The name '"..full_name.."' is already taken. Please choose another name"
    end
    if not arg.tab_name then
      if table.find(xStreamArgs.RESERVED_NAMES,arg.name) then
        return false,"The name '"..arg.name.."' is reserved. Please choose another name"
      end
    end
  end

  if (type(arg.value)=='nil') then
    return false,"Please provide a default value (makes the type unambigous)"
  end

  if arg.poll and arg.bind then
    return false,"Please specify either bind or poll for an argument, but not both"
  end   
  
  if arg.bind then
    local is_valid,err = self:is_valid_bind_value(arg.bind,type(arg.value))
    if not is_valid then
      return false,err
    end

    -- when bound, enforce the target min & max 
    local xobservable = xObservable.get_by_type_and_name(type(arg.value),arg.bind,"rns.")
    --print("min,max PRE",arg.properties.min,arg.properties.max)
    arg.properties.min = xobservable.min or arg.properties.min
    arg.properties.max = xobservable.max or arg.properties.max
    --print("min,max POST",arg.properties.min,arg.properties.max)

    -- (TODO add dummy entries to lists)

  end

  if arg.poll then
    local is_valid,err = self:is_valid_poll_value(arg.poll)
    if not is_valid then
      return false,err
    end
  end

  -- Observable needs a value in order to determine it's type.
  -- Try to evaluate the bind/poll string in order to get the 
  -- current value. If that fails, provide the default value
  local parsed_val,err
  if arg.bind then
    --print("default value for arg.bind",arg.bind)
    local bind_val_no_obs = string.sub(arg.bind,1,#arg.bind-11)
    parsed_val,err = xLib.parse_str(bind_val_no_obs)
    if not parsed_val and err then
      arg.bind = nil
      LOG("Warning: 'bind' failed to resolve: "..err)
    end
  elseif arg.poll then
    --print("default value for arg.poll",arg.poll)
    parsed_val,err = xLib.parse_str(arg.poll)
    if not parsed_val and err then
      arg.poll = nil
      LOG("Warning: 'poll' failed to resolve: "..err)
    end
  end
  --print("parsed_val",parsed_val)
  if not err then
    arg.value = parsed_val or arg.value
  else
    LOG(err)
  end

  -- seems ok, add to our document and create xStreamArg 
  if (type(arg.value) == "string") then
    arg.observable = renoise.Document.ObservableString(arg.value)
  elseif (type(arg.value) == "number") then
    arg.observable = renoise.Document.ObservableNumber(arg.value)
  elseif (type(arg.value) == "boolean") then
    arg.observable = renoise.Document.ObservableBoolean(arg.value)
  end
  arg.model = self.model
  arg.tab_name = arg_tab_name
  arg.name = arg_name

  --print(">>> type(arg.value)",type(arg.value))
  --print(">>> create xStreamArg...",rprint(arg))

  local xarg = xStreamArg(arg)

  if index then
    table.insert(self.args,index,xarg) 
  else
    table.insert(self.args,xarg) 
  end
  self.args_observable:insert(#self.args)

  --print(">>> inserted at index",index,"args length",#self.args)


  -- getter/setter methods --------------------------------
  -- as used by the callback method

  local getter = function()  
    -- index can change as arguments are rearranged
    -- so we always fetch by the name...
    --print("self:get_arg_by_name(arg.name)",arg.name,self:get_arg_by_name(arg.name))
    local val = self:get_arg_by_name(arg.name,arg.tab_name).value
    if arg.properties then
      -- apply transformation 
      if type(val)=="number" and arg.properties.zero_based then
        val = val - 1
      end
      if type(val)=="number" and 
        (arg.properties.display_as == xStreamArg.DISPLAYS[xStreamArg.DISPLAY_AS.INTEGER]) 
      then
        val = math.floor(val)
      end
    end
    return val
  end

  local setter = function(_,val)
    -- callback has specified a new value
    local xarg = self:get_arg_by_name(arg.name,arg.tab_name)
    if xarg then
      xarg.value = val
    end
  end

  -- NB: added only once, reused 
  if arg_tab_name then
    --print("self[arg_tab_name]",self[arg_tab_name],arg_tab_name,type(self[arg_tab_name]))
    if (type(self[arg_tab_name]) == "nil") then
      self[arg_tab_name] = xStreamArgsTab()
      table.insert(self._tab_names,arg_tab_name)
      --print(">>> creating xStreamArgsTab for this arg",arg.name)
    end
    if (type(self[arg_tab_name][arg_name]) == "nil") then
      --print(">>> adding tabbed arg",arg_name)
      self[arg_tab_name][arg_name] = property(getter,setter)
    end
  else
    if (type(self[arg.name]) == "nil") then
      --print(">>> adding untabbed arg",arg.name)
      self[arg.name] = property(getter,setter)
    end
  end

  --print("adding arg",arg.name)
  return true

end

-------------------------------------------------------------------------------
-- return argument by it's name/tab
-- @param str_name (string)
-- @param str_tab_name (string), optional

function xStreamArgs:get_arg_by_name(str_name,str_tab_name)
  TRACE("xStreamArgs:get_arg_by_name(str_name)",str_name)

  for _,v in ipairs(self.args) do
    if str_tab_name then
      if (v.name == str_name) and
        (v.tab_name == str_tab_name)
      then
        return v
      end
    else
      if (v.name == str_name) then
        return v
      end
    end
  end

end

-------------------------------------------------------------------------------
-- @param bind (string), the name of the observable property
-- @param str_type (string), one of xStreamArg.BASE_TYPES
-- @return bool, true when property is considered valid
-- @return string, error message when failed

function xStreamArgs:is_valid_bind_value(bind,str_type)
  TRACE("xStreamArgs:is_valid_bind_value(bind,str_type)",bind,str_type)

  local matched = xObservable.get_by_type_and_name(str_type,bind,"rns.")
  if not matched then
    local keys = table.concat(xObservable.get_keys_by_type(str_type,"rns."),"\n")
    return false,("Invalid/unsupported observable property '%s', try one of these: \n%s"):format(bind,keys)
  end
  return true

end

-------------------------------------------------------------------------------

function xStreamArgs:is_valid_poll_value(val)
  TRACE("xStreamArgs:is_valid_poll_value(val)",val)

  if string.find(val,"_observable$") then
    return false,"Error: poll needs a literal value reference, not '_observable'"
  else
    return true
  end

end

-------------------------------------------------------------------------------

function xStreamArgs:get_unique_name()

  local str_name = "new_arg"
  local counter = 1
  local arg_names = self:get_names()
  while (table.find(arg_names,str_name)) do
    str_name = ("new_arg_%d"):format(counter)
    counter = counter + 1
  end
  return str_name

end

-------------------------------------------------------------------------------

function xStreamArgs:remove(idx)
  TRACE("xStreamArgs:remove(idx)",idx)

  local arg = self.args[idx]
  if not arg then
    return
  end

  -- remove tab group if only member 
  if arg.tab_name then
    local arg_count = 0
    for k,v in ipairs(self.args) do
      if (v.tab_name == arg.tab_name) then
        arg_count = arg_count+1
      end
    end
    if (arg_count == 1) then
      self[arg.tab_name] = nil
      for k,v in ipairs(self._tab_names) do
        if (v == arg.tab_name) then
          table.remove(self._tab_names,k)
        end
      end
      --print("xStreamArgs.remove() - removed tab group",arg.tab_name,rprint(self._tab_names))
    end
  end

  --self[arg.name] = nil
  --print("self[arg.name]",self[arg.name],arg.name)
  table.remove(self.args,idx)
  self.args_observable:remove(idx)

  -- selected index should always defined
  if not self.args[self.selected_index] then
    self.selected_index = self.selected_index - 1
  end

end

-------------------------------------------------------------------------------
-- replace an existing argument, while fixing potential issues
-- @param idx (int) the argument index
-- @param arg (table), see xStreamArg.constructor
-- @return bool, true when managed to rename
-- @return string, error message when failed

function xStreamArgs:replace(idx,arg)
  TRACE("xStreamArgs:replace(idx,arg)",idx,arg)

  assert(type(idx) == "number", "Invalid argument type: idx should a number")
  assert(type(arg) == "table", "Invalid argument type: arg should a table")

  if not self.args[idx] then
    return false, "Invalid argument index"
  end

  -- name has changed, update callback? 
  if (arg.name ~= self.args[idx].full_name) then
    local str_msg = "Do you want to update the callback with the new name?"
    local choice = renoise.app():show_prompt("Renamed argument",str_msg,{"Go ahead!","Skip this step"})
    if (choice == "Go ahead!") then
      self.model:rename_argument(self.args[idx].full_name,arg.name)
    end
  end

  -- fix min,max out-of-range values in presets
  local presets = self.model.selected_preset_bank.presets
  if arg.max and arg.min then
    for k,v in ipairs(presets) do
      --print("k,v",k,v,rprint(v))
      if (k == arg.name) then
        --print("value pre",v)
        v = (v > arg.max) and arg.max or v
        v = (v < arg.min) and arg.min or v
        --print("value post",v)
      end
    end
  end

  --print("PRE self.selected_arg",self.selected_arg)
  --print("PRE self.selected_arg.value",self.selected_arg.value,type(self.selected_arg.value))
  --print("PRE self.selected_arg.observable",self.selected_arg.observable,type(self.selected_arg.observable))

  -- now replace the argument
  local cached_index = self.selected_index 
  self:remove(idx)
  local do_replace = true
  local added,err = self:add(arg,idx,do_replace)
  if not added and err then
    return false,err
  end

  self.selected_index = cached_index

  --print("POST self.selected_arg",self.selected_arg)
  --print("POST self.selected_arg.value",self.selected_arg.value,type(self.selected_arg.value))
  --print("POST self.selected_arg.observable",self.selected_arg.observable,type(self.selected_arg.observable))

  self:attach_to_song()

end

-------------------------------------------------------------------------------
-- swap the entries

function xStreamArgs:swap_index(idx1,idx2)
  TRACE("xStreamArgs:swap_index(idx1,idx2)",idx1,idx2)

  if (idx1 < 1 or idx2 < 1) then
    return false,"Cannot swap entries - either index is too low"
  elseif (idx1 > #self.args or idx2 > #self.args) then
    return false,"Cannot swap entries - either index is too high"
  end

  self.args[idx1],self.args[idx2] = self.args[idx2],self.args[idx1]
  self.args_observable:swap(idx1,idx2)

  return true

end

-------------------------------------------------------------------------------
-- return a list of arguments, prefixed by tab (if any)
-- return table<string>

function xStreamArgs:get_names()
  TRACE("xStreamArgs:get_names()")

  local t = {}
  for k,v in ipairs(self.args) do
    if (v.tab_name) then
      table.insert(t,v.tab_name.."."..v.name)
    else
      table.insert(t,v.name)
    end
  end
  return t

end

-------------------------------------------------------------------------------
-- apply a random value to boolean, numeric values

function xStreamArgs:randomize()

  for _,arg in ipairs(self.args) do

    if not arg.locked then

      local val

      if (type(arg.value) == "boolean") then
        val = (math.random(0,1) == 1) and true or false
        --print(">>> boolean random",val)
      elseif (type(arg.value) == "number") then
        if arg.properties then
          if (arg.properties.items) then
            -- popup or switch
            val = math.random(0,#arg.properties.items)
          elseif arg.properties.min and arg.properties.max then
            if (arg.properties.display_as == xStreamArg.DISPLAYS[xStreamArg.DISPLAY_AS.INTEGER]) then
              -- integer
              val = math.random(arg.properties.min,arg.properties.max)
            else
              -- float
              val = xLib.scale_value(math.random(),0,1,arg.properties.min,arg.properties.max)
            end
          end
        end
      end

      if (type(val) ~= "nil") then
        arg.observable.value = val
      end

    end

  end

end

-------------------------------------------------------------------------------
-- (re-)bind arguments when model, song or arguments has changed

function xStreamArgs:attach_to_song()
  TRACE("xStreamArgs:attach_to_song()")

  self:detach_from_song()

  for k,arg in ipairs(self.args) do
    if (arg.bind) then
      arg.bind = xStreamArg.resolve_binding(arg.bind_str)
      arg.bind:add_notifier(arg,arg.bind_notifier)
      -- call it once, to initialize value
      arg:bind_notifier()
    end
  end

end

-------------------------------------------------------------------------------

function xStreamArgs:toggle_link(arg)

  arg.linked = not arg.linked
  --local args = self.model.xstream.selected_model.args
  if not arg.linked then
    self:unset_link(arg.name)
  else
    self:set_link(arg.name)
  end

end

-------------------------------------------------------------------------------
-- @param name - set link property for all tabbed args matching this name

function xStreamArgs:set_link(name)

  self._linked[name] = {}

  for k,arg in ipairs(self.args) do
    if arg.tab_name and (arg.name == name) then
      arg.linked = true
      table.insert(self._linked[name],arg)
    end
  end

  --print(">>> post set_link",name,rprint(self._linked))

end

-------------------------------------------------------------------------------
-- @param name - unset link property for all tabbed args matching this name

function xStreamArgs:unset_link(name)

  for k,arg in ipairs(self.args) do
    if arg.tab_name and (arg.name == name) then
      arg.linked = false
    end
  end

  self._linked[name] = nil

  --print(">>> post unset_link",name,rprint(self._linked))

end

-------------------------------------------------------------------------------
-- @return true if the provided argument can be linked 
-- (has other tabbed arguments with the same name)

function xStreamArgs:count_linkable(name)
  TRACE("xStreamArgs:count_linkable(name)",name)

  local count = 0
  for k,v in ipairs(self.args) do
    if v.tab_name and (name == v.name) then
      count = count+1
    end
  end
  return count

end

-------------------------------------------------------------------------------
-- directly update linked argument values 
-- @param arg (xStreamArg)

function xStreamArgs:set_linked(arg)
  TRACE("xStreamArgs:set_linked(arg)",arg)

  for k,v in ipairs(self.args) do
    --print("v.linked,name,equal",v.linked,v.name,rawequal(arg,v))
    if (v.linked and arg.name == v.name) 
    --  and not (arg.tab_name == v.tab_name)
    then
      v.observable.value = arg.value
    --  print("set linked param to ",arg.value,arg.full_name)
    end
  end

end

-------------------------------------------------------------------------------
-- when we switch away from the model using these argument

function xStreamArgs:detach_from_song()
  TRACE("xStreamArgs:detach_from_song()")

  for k,arg in ipairs(self.args) do
    if (arg.bind_notifier) then
      --print(">>> detach_from_song - arg.bind_str",arg.bind_str)
      pcall(function()
        if arg.bind:has_notifier(arg,arg.bind_notifier) then
          arg.bind:remove_notifier(arg,arg.bind_notifier)
        end
      end) 
    end
  end

end

-------------------------------------------------------------------------------
-- execute running tasks for all registered arguments

function xStreamArgs:on_idle()
  --TRACE("xStreamArgs:on_idle()")

  for k,arg in ipairs(self.args) do
    if (type(arg.poll)=="function") then
      -- 'poll' - get current value 
      local rslt = arg.poll()
      if rslt then
        arg.observable.value = rslt
      end
    elseif (type(arg.value_update_requested) ~= "nil") then
      -- 'bind' requested an update
      --print("'bind' requested an update",arg.observable.value,type(arg.observable.value),arg.value_update_requested,type(arg.value_update_requested))
      arg.observable.value = arg.value_update_requested
      arg.value_update_requested = nil
    end
  end



end

-------------------------------------------------------------------------------
-- return arguments as a valid lua string, ready be to included
-- in a model definition - see also xStreamModel:serialize()
-- @return string (arguments)
-- @return string (default presets)

function xStreamArgs:serialize()
  TRACE("xStreamArgs:serialize()")

  local args = {}
  for idx,arg in ipairs(self.args) do

    local props = {}
    if arg.properties then
      -- remove default values from properties
      props = table.rcopy(arg.properties_initial)
      if (props.impacts_buffer == true) then
        props.impacts_buffer = nil
      end
    end

    table.insert(args,{
      name = arg.full_name,
      value = arg.value,
      properties = props,
      description = arg.description,
      bind = arg.bind_str,
      poll = arg.poll_str
    })

  end

  local presets = {}
  if self.model.selected_preset_bank then
    presets = table.rcopy(self.model.selected_preset_bank.presets)
    -- add names
    for k,v in ipairs(presets) do
      v.name = self.model.selected_preset_bank.preset_names[k]
    end
  end

  local str_args = xLib.serialize_table(args)
  local str_presets = xLib.serialize_table(presets)

  return str_args,str_presets

end



