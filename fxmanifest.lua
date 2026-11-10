fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Frank Scripts'
description 'Synced Walkable Tramway for FiveM like Nopixel V'
version '1.0.0'

shared_script '@ox_lib/init.lua'
shared_script 'config.lua'

client_scripts {
    'client.lua',
}

server_script 'server.lua'
