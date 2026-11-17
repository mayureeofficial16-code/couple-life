import { useEffect, useRef } from 'react'
import Phaser from 'phaser'

type Placed = { name: string; x: number; y: number }
type Props = { onMessage: (message: string) => void; onBillboardOpen:()=>void; decorations: string[]; placed: Placed[]; homeRooms:string[]; placing: boolean; onPlace: (x:number,y:number)=>void; remotePlayer?:{x:number;y:number}|null }
const TILE = 32

export default function PixelWorld({ onMessage, onBillboardOpen, decorations, placed, homeRooms, placing, onPlace, remotePlayer }: Props) {
  const host = useRef<HTMLDivElement>(null)
  const message = useRef(onMessage)
  const place = useRef(onPlace)
  const openAdvertising = useRef(onBillboardOpen)
  const placingNow = useRef(placing)
  const remotePosition = useRef(remotePlayer)
  useEffect(()=>{remotePosition.current=remotePlayer},[remotePlayer])
  const playerPosition = useRef({x:11,y:9})
  useEffect(() => { message.current = onMessage }, [onMessage])
  useEffect(() => { openAdvertising.current = onBillboardOpen }, [onBillboardOpen])
  useEffect(() => { place.current = onPlace; placingNow.current = placing }, [onPlace, placing])
  useEffect(() => {
    const remember=(e:Event)=>{const d=(e as CustomEvent<{x:number;y:number}>).detail;playerPosition.current=d}
    window.addEventListener('couple-position',remember)
    return()=>window.removeEventListener('couple-position',remember)
  },[])
  useEffect(() => {
    if (!host.current) return
    class Neighborhood extends Phaser.Scene {
      private player!: Phaser.GameObjects.Image
      private partner!: Phaser.GameObjects.Image
      private keys!: Record<string, Phaser.Input.Keyboard.Key>
      private lastMove = 0
      private obstacles = new Set<string>()
      private hint!: Phaser.GameObjects.Text
      private plot!: Phaser.GameObjects.Container
      constructor() { super('neighborhood') }
      create() {
        const mapWidth = 30, mapHeight = 15
        const ground = this.add.graphics()
        for (let y=0;y<mapHeight;y++) for (let x=0;x<mapWidth;x++) {
          const road = y===10 || y===11
          const pavement = y===9
          const base = road ? 0xbdaa91 : pavement ? 0xd8ccb0 : ((x+y)%3===0 ? 0x93bd83 : 0x9cc78a)
          ground.fillStyle(base,1); ground.fillRect(x*TILE,y*TILE,TILE,TILE)
          if (!road && !pavement && (x*3+y*7)%5===0) { ground.fillStyle(0xb6d298,1); ground.fillRect(x*TILE+8,y*TILE+21,3,3) }
          if (road && x%2===0) { ground.fillStyle(0xe9dec8,1); ground.fillRect(x*TILE+4,y*TILE+15,20,2) }
        }
        this.add.rectangle(12*TILE,9*TILE+15,24*TILE,2,0xbda987)
        // The shop row, park and starter house are painted from original tile-sized shapes.
        this.building(3,3,'KOPI & CO.',0xc58470,0xf3d39a)
        this.building(8,3,'MARKET',0x719a7b,0xf0d69a)
        this.building(18,3,'FLOWER SHOP',0xb9798a,0xf2d7a3)
        this.building(10,6,'OUR HOME',0xb96e64,0xf5d69c,true)
        if(homeRooms.includes('garden-room'))this.building(15,6,'GARDEN ROOM',0x73966f,0xf1d9ad)
        if(homeRooms.includes('reading-room'))this.building(6,6,'READING ROOM',0x8190a3,0xf1d9ad)
        this.tree(1,2); if(!homeRooms.includes('reading-room'))this.tree(6,6); this.tree(15,2); this.tree(21,6); this.tree(2,7); this.tree(21,7)
        this.add.rectangle(5*TILE,7*TILE,TILE*3,3,0x80a979)
        this.add.circle(5*TILE,7*TILE,17,0x9fc79a).setStrokeStyle(3,0xeff0c9)
        this.add.circle(5*TILE,7*TILE,5,0xd9bfc8)
        this.add.text(3.4*TILE,8*TILE,'SUNBEAM PARK',{fontFamily:'monospace',fontSize:'8px',color:'#fff8dc',backgroundColor:'#74966e',padding:{x:4,y:3}})
        this.makeBillboards()
        this.makePeople()
        this.partner=this.add.image(0,0,'partner').setDepth(29).setVisible(!!remotePosition.current)
        if(remotePosition.current)this.partner.setPosition(remotePosition.current.x*TILE,remotePosition.current.y*TILE)
        this.plot = this.add.container(playerPosition.current.x*TILE,playerPosition.current.y*TILE,[this.add.image(0,0,'player')]).setDepth(30)
        this.player = this.plot.getAt(0) as Phaser.GameObjects.Image
        if (decorations.includes('Tiny garden')) { this.flower(8*TILE,8*TILE); this.flower(9*TILE,8*TILE) }
        placed.forEach(item=>{
          const key=`prop-${item.name.replace(/[^a-z0-9]/gi,'').toLowerCase()}`
          this.makePropTexture(key,item.name)
          this.add.image(item.x*TILE+TILE/2,item.y*TILE+TILE/2,key).setDepth(item.y*TILE+25)
        })
        this.hint = this.add.text(8,8,'',{fontFamily:'monospace',fontSize:'9px',color:'#fff9e8',backgroundColor:'#51495bdc',padding:{x:7,y:5}}).setDepth(99).setScrollFactor(0).setVisible(false)
        this.cameras.main.setBounds(0,0,mapWidth*TILE,mapHeight*TILE).startFollow(this.plot,true,0.08,0.08).setZoom(1.15)
        this.physics.world.setBounds(0,0,mapWidth*TILE,mapHeight*TILE)
        this.keys=this.input.keyboard!.addKeys('W,A,S,D,UP,DOWN,LEFT,RIGHT,E,SPACE') as Record<string,Phaser.Input.Keyboard.Key>
        this.input.keyboard!.on('keydown-E',()=>this.interact())
        this.input.on('pointerdown',(pointer:Phaser.Input.Pointer)=>{
          if(!placingNow.current)return
          const x=Math.floor(pointer.worldX/TILE),y=Math.floor(pointer.worldY/TILE)
          if(x<7||x>17||y<7||y>9||this.obstacles.has(`${x},${y}`)){message.current('Choose an open garden tile near your home.');return}
          place.current(x,y);message.current('Your decoration has a new little home!')
        })
        window.addEventListener('couple-move',this.touchMove as EventListener)
        window.addEventListener('couple-interact',this.touchInteract)
      }
      shutdown(){window.removeEventListener('couple-move',this.touchMove as EventListener);window.removeEventListener('couple-interact',this.touchInteract)}
      private touchMove=(event:CustomEvent<{dx:number;dy:number}>)=>{this.step(event.detail.dx,event.detail.dy)}
      private touchInteract=()=>this.interact()
      update(time:number){
        const remote=remotePosition.current
        this.partner.setVisible(!!remote)
        if(remote)this.partner.setPosition(remote.x*TILE,remote.y*TILE).setDepth(remote.y*TILE+40)
        if (time-this.lastMove<135) return
        const k=this.keys
        if (k.LEFT.isDown||k.A.isDown) this.step(-1,0)
        else if(k.RIGHT.isDown||k.D.isDown) this.step(1,0)
        else if(k.UP.isDown||k.W.isDown) this.step(0,-1)
        else if(k.DOWN.isDown||k.S.isDown) this.step(0,1)
      }
      private step(dx:number,dy:number){
        const nx=Math.round(this.plot.x/TILE)+dx, ny=Math.round(this.plot.y/TILE)+dy
        if(nx<0||ny<0||nx>=30||ny>=15||this.obstacles.has(`${nx},${ny}`)) return
        this.lastMove=this.time.now; this.plot.setPosition(nx*TILE,ny*TILE); this.plot.setDepth(ny*TILE+40)
        window.dispatchEvent(new CustomEvent('couple-position',{detail:{x:nx,y:ny}}))
        this.player.setY((this.player.y===0?1:0));
        this.hint.setText('').setVisible(false)
      }
      private interact(){
        const x=Math.round(this.plot.x/TILE), y=Math.round(this.plot.y/TILE)
        const boards=Array.from({length:10},(_,i)=>({x:1+i*3,y:i%2===0?12:13,name:`Billboard ${String(i+1).padStart(2,'0')}`}))
        const places=[{x:4,y:4,name:'Kopi & Co. Cafe'},{x:9,y:4,name:'Sunbeam Market'},{x:19,y:4,name:'Flower Shop'},{x:11,y:7,name:'Your home'},...boards]
        const nearest=places.find(p=>Math.abs(p.x-x)+Math.abs(p.y-y)<=2)
        if(nearest){const billboard=nearest.name.startsWith('Billboard');if(billboard)openAdvertising.current();message.current(billboard?`${nearest.name} · PROMOTE YOUR BRAND HERE · Advertise in Couple Life.`:`${nearest.name} · Welcome in!`);this.hint.setText(`E  ${nearest.name}`).setPosition(10,10).setVisible(true)}
        else {this.hint.setText('Walk up to a building and press E').setPosition(10,10).setVisible(true)}
      }
      private building(x:number,y:number,label:string,roof:number,wall:number,home=false){
        const g=this.add.graphics(),w=home?5:4,h=3,px=x*TILE,py=y*TILE
        g.fillStyle(0x617558,0.35);g.fillRect(px-4,py+h*TILE-2,w*TILE+8,7)
        g.fillStyle(wall,1);g.fillRect(px,py+18,w*TILE,h*TILE-18)
        g.fillStyle(roof,1);g.fillPoints([{x:px-8,y:py+21},{x:px+w*TILE/2,y:py-15},{x:px+w*TILE+8,y:py+21}],true)
        g.fillStyle(0x9e6857,1);g.fillRect(px+w*TILE/2-10,py+45,20,44)
        for(let i=0;i<(home?2:2);i++){g.fillStyle(0x9ed0ce,1);g.fillRect(px+13+i*(w*TILE-35),py+37,19,18);g.lineStyle(3,0xffedcc);g.strokeRect(px+13+i*(w*TILE-35),py+37,19,18)}
        g.fillStyle(0xfff5d9,1);g.fillRoundedRect(px+12,py+7,w*TILE-24,16,3)
        this.add.text(px+w*TILE/2,py+9,label,{fontFamily:'monospace',fontSize:'7px',color:'#5f574d'}).setOrigin(.5,0)
        for(let yy=y;yy<y+h;yy++)for(let xx=x;xx<x+w;xx++)this.obstacles.add(`${xx},${yy}`)
      }
      private tree(x:number,y:number){
        const px=x*TILE,py=y*TILE,g=this.add.graphics();g.fillStyle(0x755847,1);g.fillRect(px+13,py+14,7,21)
        g.fillStyle(0x528b63,1);g.fillRect(px+3,py+4,13,12);g.fillRect(px+13,py,14,13);g.fillRect(px+18,py+10,12,13);g.fillStyle(0x72a969,1);g.fillRect(px+7,py,10,9);g.fillRect(px+21,py+5,8,9)
        this.obstacles.add(`${x},${y}`)
      }
      private flower(x:number,y:number){const g=this.add.graphics();g.fillStyle(0x59925d,1);g.fillRect(x-2,y-1,4,12);g.fillStyle(0xf4c965,1);g.fillRect(x-6,y-8,5,5);g.fillRect(x+2,y-8,5,5);g.fillRect(x-2,y-12,5,5);g.fillStyle(0xf6ecda,1);g.fillRect(x-2,y-5,5,5)}
      private makeBillboards(){for(let i=0;i<10;i++){const x=1+i*3,y=i%2===0?12:13,px=x*TILE,py=y*TILE,g=this.add.graphics();g.fillStyle(0x725946,1);g.fillRect(px-2,py-10,4,21);g.fillStyle(i<5?0xf1d7a1:i<8?0xd6a9ad:0xc49a58,1);g.fillRoundedRect(px-26,py-28,52,20,2);g.lineStyle(2,0x755a4c,1);g.strokeRoundedRect(px-26,py-28,52,20,2);this.add.text(px,py-26,`PROMOTE\nYOUR BRAND`,{fontFamily:'monospace',fontSize:'5px',align:'center',color:'#5d4c40',lineSpacing:0}).setOrigin(.5,0).setDepth(py+5)}}
      private makePropTexture(key:string,name:string){
        const g=this.add.graphics()
        if(name==='Tiny garden'||name==='Flower rug'){g.fillStyle(0x699364,1);g.fillRect(2,11,28,16);g.fillStyle(0xe6bb61,1);g.fillRect(7,6,5,5);g.fillRect(18,3,5,5);g.fillStyle(0xf5ebd6,1);g.fillRect(8,7,3,3);g.fillRect(19,4,3,3)}
        else if(name==='Warm lamp'){g.fillStyle(0x8b6955,1);g.fillRect(14,12,5,14);g.fillStyle(0xf3cd72,1);g.fillRect(8,3,17,10);g.fillStyle(0xffedaa,1);g.fillRect(12,6,9,4)}
        else if(name==='Love seat'){g.fillStyle(0xb77474,1);g.fillRect(2,11,28,14);g.fillStyle(0xd9948d,1);g.fillRect(4,6,24,13);g.fillStyle(0x70524d,1);g.fillRect(5,24,4,4);g.fillRect(24,24,4,4)}
        else if(name==='Window seat'){g.fillStyle(0xb98b69,1);g.fillRect(1,15,30,10);g.fillStyle(0xf2d59f,1);g.fillRect(4,10,24,7);g.fillStyle(0x8f705b,1);g.fillRect(5,24,3,4);g.fillRect(25,24,3,4)}
        else {g.fillStyle(0x986e53,1);g.fillRect(6,14,20,8);g.fillRect(8,22,3,5);g.fillRect(21,22,3,5);g.fillStyle(0xe8bd7c,1);g.fillRect(8,11,16,5);g.fillStyle(0xf2dcae,1);g.fillRect(15,6,8,5)}
        g.generateTexture(key,34,30);g.destroy()
      }
      private makeAvatarTexture(key:string,shirt:number,skin:number){
        const g=this.add.graphics();g.fillStyle(0x55493f,1);g.fillRect(9,1,14,7);g.fillRect(7,6,18,10);g.fillStyle(skin,1);g.fillRect(10,7,12,11);g.fillStyle(0x443a42,1);g.fillRect(12,11,2,2);g.fillRect(19,11,2,2);g.fillStyle(shirt,1);g.fillRect(8,18,17,12);g.fillStyle(0x583f53,1);g.fillRect(9,29,6,6);g.fillRect(20,29,6,6);g.generateTexture(key,34,38);g.destroy()
      }
      private makePeople(){this.makeAvatarTexture('player',0xd98276,0xd29c70);this.makeAvatarTexture('partner',0x719aab,0xc58e69)}
    }
    const game=new Phaser.Game({type:Phaser.AUTO,parent:host.current,width:960,height:340,backgroundColor:'#9cc78a',pixelArt:true,roundPixels:true,physics:{default:'arcade',arcade:{debug:false}},scale:{mode:Phaser.Scale.FIT,autoCenter:Phaser.Scale.CENTER_BOTH},scene:[Neighborhood]})
    return()=>{game.destroy(true)}
  },[decorations,placed,homeRooms])
  const move=(dx:number,dy:number)=>window.dispatchEvent(new CustomEvent('couple-move',{detail:{dx,dy}}))
  const interact=()=>window.dispatchEvent(new Event('couple-interact'))
  return <div className={`pixel-world-wrap ${placing?'is-placing':''}`}><div className="phaser-host" ref={host} aria-label="Walkable pixel art neighborhood"/>{placing&&<div className="placement-prompt">Tap an open tile in the garden to place your decoration</div>}<div className="pixel-touch-pad"><button onClick={()=>move(0,-1)}>↑</button><div><button onClick={()=>move(-1,0)}>←</button><button onClick={()=>move(0,1)}>↓</button><button onClick={()=>move(1,0)}>→</button></div></div><button className="interact-touch" onClick={interact}>E · Interact</button></div>
}
