import { ModelOption } from './Types';

export interface ModelLevel { effort:string; wireId:string }
export interface ModelFamily { id:string; name:string; levels:ModelLevel[] }

const LEVELS:string[]=['low','medium','high','xhigh','max'];

export function strengthName(value:string):string {
  return value==='low'?'低':value==='medium'?'中':value==='high'?'高':value==='xhigh'?'极高':value==='max'?'最高':value;
}

/** Wire aliases remain intact for queued requests; the UI presents model families. */
export function modelFamilies(models:ModelOption[]):ModelFamily[] {
  const families:ModelFamily[]=[];
  for(const model of models) {
    const level=model.efforts.length===1?model.efforts[0]:'';
    const suffix='-'+level;
    const grouped=!!level && model.id.endsWith(suffix) && /\((Low|Medium|High|XHigh|Max)\)$/i.test(model.name);
    const id=grouped?model.id.substring(0,model.id.length-suffix.length):model.id;
    let family=families.find((item:ModelFamily)=>item.id===id);
    if(!family) {
      family={id:id,name:model.id==='default'?'主机当前配置':model.name.replace(/\s*\((Low|Medium|High|XHigh|Max)\)\s*$/i,''),levels:[]};
      families.push(family);
    }
    for(const effort of model.efforts)if(!family.levels.some((item:ModelLevel)=>item.effort===effort))family.levels.push({effort:effort,wireId:model.id});
  }
  for(const family of families)family.levels.sort((a:ModelLevel,b:ModelLevel)=>LEVELS.indexOf(a.effort)-LEVELS.indexOf(b.effort));
  return families;
}

export function selectedFamily(models:ModelOption[],wireId:string):ModelFamily {
  return modelFamilies(models).find((family:ModelFamily)=>family.levels.some((level:ModelLevel)=>level.wireId===wireId)) || {id:'',name:'选择模型',levels:[]};
}
