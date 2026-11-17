import { Artifact } from './Types';
import { isPicture } from '../services/ImagePreviews';

export class PictureSource implements IDataSource {
  private items:Artifact[]=[];
  private listeners:DataChangeListener[]=[];
  totalCount():number {return this.items.length;}
  getData(index:number):Artifact {return this.items[index];}
  registerDataChangeListener(listener:DataChangeListener):void {this.listeners.push(listener);}
  unregisterDataChangeListener(listener:DataChangeListener):void {this.listeners=this.listeners.filter((item:DataChangeListener)=>item!==listener);}
  replace(files:Artifact[]):void {
    this.items=files.filter((file:Artifact)=>isPicture(file));
    this.listeners.forEach((listener:DataChangeListener)=>listener.onDataReloaded());
  }
}
