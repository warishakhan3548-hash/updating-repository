package android.content;
import java.io.File;
import android.content.res.AssetManager;
public final class Context {
    private final AssetManager assets;private final File files;
    public Context(File assets,File files){this.assets=new AssetManager(assets);this.files=files;}
    public AssetManager getAssets(){return assets;}
    public File getFilesDir(){return files;}
}
