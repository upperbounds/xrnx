--[[----------------------------------------------------------------------------
-- Duplex.Device
----------------------------------------------------------------------------]]--

--[[
Requires: ControlMap

A generic device class (OSC or MIDI based)
+ Specify the message stream for user-generated events
+ Listen for incoming messages from the device

--]]

module("Duplex", package.seeall);

class 'Device'

function Device:__init(name, protocol)
--print('protocol='..protocol)

    self.name = name
	self.protocol = protocol
	self.message_stream = nil
	self.control_map = ControlMap()

	-- default palette is provided by the display
	self.palette = {}		

end

function Device:get_protocol()
--print('Device:getProtocol()')
	return self.protocol
end

function Device:set_controller_map(xml_file)
	self.control_map.load_definition(self.control_map,xml_file)

end

-- Converts the color to an output value
-- (override with device-specific implementation)
function Device:color_to_value()

end
