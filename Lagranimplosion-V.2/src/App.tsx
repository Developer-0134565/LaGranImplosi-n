import { useEffect, useMemo, useState } from 'react'
import type { CSSProperties } from 'react'
import './App.css'
import './styles/fonts.css'
import './styles/ui-overhaul.css'
import './styles/definition-ui.css'
import './styles/template-system.css'
import { supabase } from './lib/supabase'
import GalaxyView from './GalaxyView'

type FontRole='title'|'heading'|'body'|'number'|'button'
type FontSettings=Record<FontRole,string>
type View='overview'|'buildings'|'research'|'shipyard'|'defense'|'fleet'|'galaxy'|'expedition'|'messages'
type PlanetPlayer={id:string;username:string;is_guest:boolean}
type Planet={id:string;name:string;galaxy:number;system:number;position:number;is_homeworld:boolean;is_destroyed:boolean;players:PlanetPlayer[];planet_resources:Array<{metal:number|string;crystal:number|string;deuterium:number|string;energy:number|string}>}
type Definition={id:string;name:string;description?:string|null;max_level?:number|null;base_metal?:number|string|null;base_crystal?:number|string|null;base_deuterium?:number|string|null;base_build_time_seconds?:number|string|null;base_research_time_seconds?:number|string|null;ship_type?:string|null;attack?:number|string|null;shield?:number|string|null;hull?:number|string|null;cargo_capacity?:number|string|null;speed?:number|string|null;fuel_consumption?:number|string|null;metal_cost?:number|string|null;crystal_cost?:number|string|null;deuterium_cost?:number|string|null;base_build_time?:number|string|null;[key:string]:unknown}
type QueueRow={id:string;building_id?:string;research_id?:string;ship_id?:string;defense_id?:string;target_level?:number;quantity?:number;finishes_at:string;status:string}
type FleetRow={id:string;mission_type:string;status:string;destination_galaxy:number;destination_system:number;destination_position:number;arrives_at:string;returns_at:string|null}
type MessageCategory='COMBATE'|'EXPEDICIONES'|'ESPIONAJE'|'TRANSPORTES'
type MessageRow={id:string;category:MessageCategory;title:string;body:string;created_at:string}

const FONT_STORAGE_KEY='lagranimplosion-fonts'
const fonts:Record<FontRole,string[]>={title:['Orbitron','Audiowide','Michroma','Oxanium'],heading:['Rajdhani','Oxanium','Exo 2','Space Grotesk'],body:['Exo 2','Inter','Space Grotesk','Rajdhani'],number:['Share Tech Mono','JetBrains Mono','Orbitron'],button:['Oxanium','Rajdhani','Orbitron','Exo 2']}
const presets:Record<string,FontSettings>={Deuteria:{title:'Orbitron',heading:'Rajdhani',body:'Exo 2',number:'Share Tech Mono',button:'Oxanium'},Militar:{title:'Michroma',heading:'Oxanium',body:'Exo 2',number:'Share Tech Mono',button:'Rajdhani'},'Sci-Fi moderno':{title:'Audiowide',heading:'Space Grotesk',body:'Inter',number:'JetBrains Mono',button:'Oxanium'}}
const defaultFonts={...presets.Deuteria};const allFonts=Array.from(new Set(Object.values(fonts).flat()))
const navItems:Array<{id:View;label:string;icon:string}>= [{id:'overview',label:'OVERVIEW',icon:'⌂'},{id:'buildings',label:'EDIFICIOS',icon:'▦'},{id:'research',label:'INVESTIGACIÓN',icon:'⚗'},{id:'shipyard',label:'HANGAR',icon:'✦'},{id:'defense',label:'DEFENSAS',icon:'⬢'},{id:'fleet',label:'FLOTA',icon:'➤'},{id:'galaxy',label:'GALAXIA',icon:'✧'},{id:'expedition',label:'EXPEDICIONES',icon:'◎'},{id:'messages',label:'MENSAJES',icon:'✉'}]
function isValidFont(role:FontRole,value:unknown):value is string{return typeof value==='string'&&fonts[role].includes(value)}
function sanitizeFontSettings(value:unknown):FontSettings{if(!value||typeof value!=='object')return{...defaultFonts};const p=value as Partial<FontSettings>;return{title:isValidFont('title',p.title)?p.title:defaultFonts.title,heading:isValidFont('heading',p.heading)?p.heading:defaultFonts.heading,body:isValidFont('body',p.body)?p.body:defaultFonts.body,number:isValidFont('number',p.number)?p.number:defaultFonts.number,button:isValidFont('button',p.button)?p.button:defaultFonts.button}}
function loadSavedFonts(){try{const saved=localStorage.getItem(FONT_STORAGE_KEY);return saved?sanitizeFontSettings(JSON.parse(saved)):{...defaultFonts}}catch{return{...defaultFonts}}}
function saveFontSettings(s:FontSettings){try{localStorage.setItem(FONT_STORAGE_KEY,JSON.stringify(s))}catch{}}
function fontStack(font:string,fallback:string){return`"${font}", ${fallback}`}
function getFontVariables(s:FontSettings):CSSProperties{return{'--font-title':fontStack(s.title,'sans-serif'),'--font-heading':fontStack(s.heading,'sans-serif'),'--font-body':fontStack(s.body,'sans-serif'),'--font-number':fontStack(s.number,'monospace'),'--font-button':fontStack(s.button,'sans-serif')} as CSSProperties}
function formatNumber(value:number|string|undefined|null){if(value===undefined||value===null)return'—';const n=Number(value);return Number.isFinite(n)?new Intl.NumberFormat('es-ES',{maximumFractionDigits:0}).format(n):'—'}
function formatDuration(value:number|string|undefined|null){const seconds=Number(value);if(!Number.isFinite(seconds)||seconds<=0)return'—';const total=Math.round(seconds);const days=Math.floor(total/86400);const hours=Math.floor((total%86400)/3600);const minutes=Math.floor((total%3600)/60);const secs=total%60;return days?`${days}d ${hours}h`:hours?`${hours}h ${minutes}m`:minutes?`${minutes}m ${secs}s`:`${secs}s`}
function coordinates(p:Pick<Planet,'galaxy'|'system'|'position'>){return`[${p.galaxy}:${p.system}:${p.position}]`}
function formatTime(value?:string|null){if(!value)return'—';return new Date(value).toLocaleString('es-ES',{hour:'2-digit',minute:'2-digit',second:'2-digit'})}