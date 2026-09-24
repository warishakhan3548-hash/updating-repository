package android.content.res;
import java.io.*;
public final class AssetManager {
    private final File root;
    public AssetManager(File root){this.root=root;}
    public String[] list(String path){return new File(root,path).list();}
    public InputStream open(String path)throws IOException{return new FileInputStream(new File(root,path));}
}
