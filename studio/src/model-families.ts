import type { Model } from './types';
export interface ModelFamily {id:string;name:string;levels:{effort:string;wireId:string}[]}
const order=['low','medium','high','xhigh','max'];
export const strengthName=(value:string)=>({low:'低',medium:'中',high:'高',xhigh:'极高',max:'最高'}[value] || value);
export function modelFamilies(models:Model[]):ModelFamily[] {
  const families:ModelFamily[]=[];
  for(const model of models) {
    const level=model.efforts.length===1?model.efforts[0]:'';
    const grouped=!!level && model.id.endsWith('-'+level) && /\((Low|Medium|High|XHigh|Max)\)$/i.test(model.name);
    const id=grouped?model.id.slice(0,-level.length-1):model.id;
    let family=families.find(item=>item.id===id);
    if(!family) {family={id,name:model.id==='default'?'主机当前配置':model.name.replace(/\s*\((Low|Medium|High|XHigh|Max)\)\s*$/i,''),levels:[]};families.push(family);}
    for(const effort of model.efforts)if(!family.levels.some(item=>item.effort===effort))family.levels.push({effort,wireId:model.id});
  }
  for(const family of families)family.levels.sort((a,b)=>order.indexOf(a.effort)-order.indexOf(b.effort));
  return families;
}
export const selectedFamily=(models:Model[],wireId:string)=>modelFamilies(models).find(family=>family.id===wireId || family.levels.some(level=>level.wireId===wireId));
