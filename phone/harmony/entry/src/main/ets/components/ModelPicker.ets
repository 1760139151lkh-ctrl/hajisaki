import { Palette } from '../design/Theme';
import { ModelOption } from '../model/Types';
import { ModelFamily, ModelLevel, modelFamilies, selectedFamily, strengthName } from '../model/ModelFamilies';

@Component
export struct ModelPicker {
  @Prop colors:Palette=new Palette();
  @Prop models:ModelOption[]=[];
  @Prop model:string='default';
  @Prop effort:string='medium';
  @Prop interactive:boolean=true;
  @Prop dense:boolean=false;
  onSelect:(model:string,effort:string)=>void=()=>{};
  @State opened:boolean=false;
  @State mode:string='models';

  private family():ModelFamily {return selectedFamily(this.models,this.model);}
  private choices():ModelFamily[] {
    const values=modelFamilies(this.models);
    const explicit=values.filter((item:ModelFamily)=>item.id!=='default');
    return explicit.length?explicit:values;
  }
  private open(mode:string):void {this.mode=mode;this.opened=true;}
  private choose(family:ModelFamily):void {
    const level=family.levels.find((item:ModelLevel)=>item.effort===this.effort) || family.levels.find((item:ModelLevel)=>item.effort==='medium') || family.levels[0];
    if(level)this.onSelect(level.wireId,level.effort);
    this.opened=false;
  }
  private chooseLevel(level:ModelLevel):void {this.onSelect(level.wireId,level.effort);this.opened=false;}
  @Builder
  private FamilyButton() {
    Button() { Row({space:10}) {
      Text(this.family().name).fontSize(this.dense?12:16).fontColor(this.colors.text).maxLines(2).layoutWeight(1).textAlign(TextAlign.Start)
      Text('⌄').fontSize(19).fontColor(this.colors.secondary)
    }.width('100%') }.width('100%').height(this.dense?44:52).padding({left:this.dense?0:16,right:this.dense?8:16})
      .backgroundColor(this.dense?Color.Transparent:this.colors.raised).borderRadius(14)
      .border({width:this.dense?0:0.5,color:this.colors.border}).enabled(this.interactive).onClick(()=>this.open('models'))
  }
  @Builder
  private Sheet() {
    Column({space:0}) {
      Row({space:12}) {
        Text(this.mode==='models'?'选择模型':'思考强度').fontSize(19).fontColor(this.colors.text).layoutWeight(1)
        Button('收起').fontSize(14).height(44).fontColor(this.colors.accent).backgroundColor(Color.Transparent).onClick(()=>{this.opened=false;})
      }.width('100%').padding({left:22,right:14,top:4,bottom:8})
      Scroll() {
        Column({space:4}) {
          if(this.mode==='models') ForEach(this.choices(),(family:ModelFamily)=>{
            Button() { Row({space:14}) {
              Text(family.name).fontSize(16).fontColor(this.colors.text).layoutWeight(1).textAlign(TextAlign.Start)
              if(family.id===this.family().id) Text('✓').fontSize(18).fontColor(this.colors.accent)
            }.width('100%') }.width('100%').constraintSize({minHeight:52}).padding({left:16,right:16,top:12,bottom:12})
              .borderRadius(12).backgroundColor(family.id===this.family().id?this.colors.surface:Color.Transparent).onClick(()=>this.choose(family))
          },(family:ModelFamily)=>family.id)
          else ForEach(this.family().levels,(level:ModelLevel)=>{
            Button() { Row() {
              Text(strengthName(level.effort)).fontSize(16).fontColor(this.colors.text).layoutWeight(1).textAlign(TextAlign.Start)
              if(level.effort===this.effort)Text('✓').fontSize(18).fontColor(this.colors.accent)
            }.width('100%') }.width('100%').height(50).padding({left:16,right:16}).borderRadius(12)
              .backgroundColor(level.effort===this.effort?this.colors.surface:Color.Transparent).onClick(()=>this.chooseLevel(level))
          },(level:ModelLevel)=>level.effort)
        }.width('100%').padding({left:12,right:12,bottom:20})
      }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Auto)
    }.width('100%').height('100%').backgroundColor(this.colors.raised)
  }
  build() {
    Column({space:12}) {
      if(this.dense) Row({space:10}) {
        Column() {this.FamilyButton()}.layoutWeight(1)
        if(this.family().levels.length>1) Button('思考 · '+strengthName(this.effort)).fontSize(12).height(40)
          .fontColor(this.colors.accent).backgroundColor(this.colors.raised).padding({left:12,right:12})
          .enabled(this.interactive).onClick(()=>this.open('levels'))
      }.width('100%')
      else {
        this.FamilyButton()
        if(this.family().levels.length>1) Column({space:8}) {
          Text('思考强度').fontSize(12).fontColor(this.colors.secondary).width('100%')
          Row({space:8}) {
            ForEach(this.family().levels,(level:ModelLevel)=>{
              Button(strengthName(level.effort)).fontSize(13).height(40).layoutWeight(1).padding({left:6,right:6})
                .fontColor(level.effort===this.effort?this.colors.background:this.colors.secondary)
                .backgroundColor(level.effort===this.effort?this.colors.accent:this.colors.surface)
                .enabled(this.interactive).onClick(()=>this.onSelect(level.wireId,level.effort))
            },(level:ModelLevel)=>level.effort)
          }.width('100%')
        }.width('100%')
      }
    }.width('100%').bindSheet(this.opened,this.Sheet(),{
      height:this.mode==='models'?'45%':260,backgroundColor:this.colors.raised,showClose:false,dragBar:true,
      maskColor:'#66000000',onDisappear:()=>{this.opened=false;}
    })
  }
}
