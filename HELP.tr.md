# CNC G-Coder — Kullanım Kılavuzu

*(Bu kılavuz uygulamanın içinde de bulunur: ⌘? ya da araç çubuğundaki Help düğmesi.)*

## İş akışına genel bakış

1. Gerber + delme dosyalarını EasyEDA ya da KiCad'den bir klasöre dışa aktarın.
2. **Choose Folder** (araç çubuğu) — katmanlar dosya adından otomatik olarak tanınır.
3. Takımlarınızı, derinlikleri ve ilerlemeleri ayarlayın (ya da bir **Preset** yükleyin). Kenar çubuğu yalnızca seçili programın ayarlarını gösterir; en üstteki katman menüsü hem önizlemeyi hem ayarları değiştirir; tüm programların paylaştığı parametreler için orada **Machine setup**'ı seçin.
4. Önizlemeyi inceleyin: her programı seçin, oynatın, yan görünümde derinlikleri ve toplam süre tahminini kontrol edin.
5. **Generate** — hedef klasörü seçin (ya da New Folder ile oluşturun); tüm `.ngc` programları oraya yazılır.
6. Sırayla işleyin: ön bakır izolasyonu → delikler (delme dosyası başına bir program; M0 duraklamalarında ucu değiştirin) → kartı çevirin → arka bakır → dış hat kesimi (köprüler kartı tutar) → köprü tırnaklarını kırın/eğeleyin.
7. Lehim maskesi: işlenmiş kartı UV lehim maskesiyle boyayın, kürleyin, ardından pad açıklıklarını temizlemek için `top-mask-etch.ngc` / `bottom-mask-etch.ngc` dosyalarını çalıştırın.

Freze yerine (ya da yanında) lazer kazıyıcı kullanmak: her program 1:1 çizim (SVG, PDF ya da PNG) olarak da dışa aktarılabilir — bkz. *Lazer kazıma ve çizim dışa aktarma*.

## Proje klasörü ve algılama

EasyEDA dışa aktarımları uzantıdan tanınır: `Gerber_TopLayer.GTL`, `Gerber_BottomLayer.GBL`, `Gerber_BoardOutlineLayer.GKO`, lehim maskeleri `.GTS`/`.GBS`, serigrafiler `.GTO`/`.GBO` ve `.DRL` delme dosyaları. EasyEDA delikleri PTH / PTH-via / NPTH dosyalarına ayırır; pcb2gcode her çalıştırmada tek bir delme dosyası kabul ettiğinden her biri ayrı bir program olur.

KiCad dışa aktarımları KiCad'in katman adlarından tanınır: `board-F_Cu.gbr` / `board-B_Cu.gbr` (bakır), `board-Edge_Cuts.gbr` (dış hat), `board-F_Mask.gbr` / `board-B_Mask.gbr`, `board-F_Silkscreen.gbr` / `board-B_Silkscreen.gbr` ve `board.drl` ya da `board-PTH.drl` + `board-NPTH.drl`. Pasta, fab, courtyard, iç bakır, delik haritası ve job dosyaları yok sayılır. KiCad'in delme iletişim kutusunda **Excellon** biçimini seçin (Gerber X2 değil) ve çizim ile delme iletişim kutularında aynı başlangıç ayarını kullanın (ikisinde de "drill/place file origin" ya da hiçbirinde); yoksa delikler bakıra göre kaymış çıkar. "Use Protel filename extensions" ile yapılan dışa aktarımlar da çalışır.

Generate, programların nereye yazılacağını sorar (iletişim kutusunun New Folder düğmesi yeni bir hedef oluşturur); seçim proje değiştirene kadar hatırlanır. Canlı önizleme geçici bir klasör kullanır ve Generate'e basana kadar dosyalarınıza asla dokunmaz.

## Takımlar ve V uçlar — önce bunu okuyun

Girdiğiniz her çap, tam olarak kullandığınız uçla, **çalışma derinliğindeki etkin kesme çapı** olmalıdır.

- **Düz / parmak frezeler**: etkin = yazılı çap, olduğu gibi girin.
- **V uçlar** (izolasyon için olağan seçim — 0,1 mm düz uçlar kolayca kırılır): koni derinlikle genişler:
  `etkin ≈ uç + 2 × |kesme derinliği| × tan(yarım açı)`
  0,1 mm uç, −0,06 mm'de: 30° V ≈ **0,13 mm** · 60° V ≈ **0,17 mm** · 90° V ≈ **0,22 mm**.
  Bunun yerine uç boyutunu girmek her izi tasarlanandan ince, izolasyonu istenenden dar yapar — sessizce.
- **Doğrulama**: bir test kartı işleyin (File → Generate Test Board…) ve 0,2 mm'lik test izini ölçün. 0,1 olarak girilmiş 60° V uçla ~0,13 mm ölçüyorsa etkin çapınız girdiğinizden ~0,07 mm büyüktür — tasarımı değil, parametreyi düzeltin.

- **V-bit modu**: izolasyon, maske ya da serigrafide **Bit → V-bit** seçip uç ve açıyı girin; derinlikteki genişlik sizin için hesaplanır (ve kesme derinliğini izler).

## Test kartları

**File → Generate Test Board…** (⇧⌘T), kurulumunuzla ilgili tek bir soruyu yanıtlayan küçük bir kart keser. Her testin kendi ucu (**Bit**, Tool Library'den; test başına hatırlanır — varsayılan bakır izolasyon ucu, delik testi için delik frezeleme ucu) ve kendi ayarları vardır; güvenli Z, dalma boşluğu ve izolasyon genişliği projeden gelir. Sonuç, bir `.txt` açıklama dosyasının yanına `.ngc` olarak yazılır ve önizlemede her program gibi gösterilir; oynatılabilir ve makineye gönderilebilir.

- **Parameter test board** — üretim izolasyonu için kesme derinliğini ve ilerlemeyi bulur. Bir yama ızgarası: satırlar **kesme derinliğini** (…'den …'e), sütunlar **XY ilerlemesini** tarar; her yamada 0,2 / 0,3 / 0,4 mm izler vardır. Her iz, kapalı bir izolasyon hendeği içindeki iki prob padi arasında uzanır; süreklilik modundaki bir multimetre izin sağ kalıp kalmadığını (pad'den pad'e öter) ve izolasyonun tam olup olmadığını (pad'den çevre bakıra sessiz kalır) söyler. **Board size** ve **Grid** (ilerleme × derinlik) yerleşimi belirler; **Suggest** kart boyutuna göre bir ızgara seçer. Açıklama dosyası her yamayı derinlik ve ilerlemesiyle eşler.
- **Backlash test** — 75 × 75 mm'lik bir kartta X ve Y eksenlerindeki boşluğu ölçer. Eksen başına bir düz çizgi, zıt yönlerden ulaşılan iki yarım olarak kesilir: yarımların birleştiği yerdeki basamak o eksenin boşluğudur. 50 mm'lik bir kare ve Ø30 bir daire de bunu gösterir — kısa kenarlar, oval. Basamağı Machine setup → Backlash compensation'a girin ve iki çizgi de düz çıkana kadar testi yeniden kesin (bkz. *Boşluk telafisi*).
- **Hole fit test** — bir pime uyan delik boyutunu bulur. Listelediğiniz her **delik boyutu** (satırlar) birkaç **varyant** (sütunlar: boyut artı mm cinsinden bir boşluk) olarak frezelenir; üretimde deliklerin frezelendiği gibi — yüzeyden aşağı bir spiral, ardından bir temizleme dairesi. Pimi satırındaki her deliğe itin ve istediğiniz gibi oturan varyantı alın; deliği o boyutta tasarlayın. Gerçek kartla aynı uçla frezeleyin.

## Projeler

Bir proje (`.cncproj`) kendi içinde bütün bir **pakettir**: Finder onu tek dosya gibi gösterir, ama sağ tık → **Paket İçeriğini Göster** şunu açar

```
Board.cncproj/
  project.json   parametreler (takımlar, derinlikler, ilerlemeler, başlangıç…), katman rolleri, kılavuzlar, her dosyanın nereden geldiği
  Layers/        Gerber ve delme dosyalarının kendileri, değiştirilmemiş
```

Projeyi tek başına taşıyın ya da kopyalayın — katmanlarını asla kaybetmez. (E-posta ile göndermek için önce sıkıştırın; Mail bunu otomatik yapar.) Bir proje açıldığında dosyaları özel bir çalışma klasörüne kopyalanır; asıllara gerek kalmaz ve asla değiştirilmezler.

- **File → New Project** (⌘N), **Open Project…** (⌘O), **Open Recent**, **Save Project** (⌘S), **Save Project As…** (⇧⌘S). Aynı eylemler kenar çubuğunun **Open** menüsünde de vardır. Pencere başlığı projeyi ve kaydedilmemiş değişiklik varsa "Edited" ibaresini gösterir; New, Open ve Quit bunları atmadan önce sorar.
- **Open Gerber Folder…** (⇧⌘O), bir EasyEDA ya da KiCad dışa aktarım klasöründen, katmanları eskisi gibi dosya adından algılayarak adsız bir proje başlatır.
- Paketlenmiş kopyalar projenin kullandıklarıdır. Gerber'leri PCB düzenleyicinizden yeniden dışa aktarırsanız **Import Layer…** ya da **Replace…** ile getirin (ya da yeni dışa aktarım klasörünü açın), sonra kaydedin. Bir katmandaki **Show Original in Finder**, hâlâ varsa paketlendiği dosyayı gösterir.
- Önceki sürümlerle kaydedilmiş projeler (katmanları gömülü ya da bağlantılı tek dosya) yine açılır ve bir sonraki kayıtta pakete dönüşür.
- Finder, uygulama bir kez çalıştırıldıktan sonra paketi tek dosya olarak gösterir (bu, proje türünü kaydeder); ondan önce `….cncproj` adlı bir klasör gibi görünür.
- Bir proje açmak geçerli parametreleri projeninkilerle değiştirir.

### Tek tek katman içe aktarma

**File → Import Layer…** (⌘I) ya da kenar çubuğunda Layer files altındaki **Import Layer…**, herhangi bir yerden Gerber ya da Excellon dosyaları ekler. Her dosyanın rolü adından tahmin edilir (delme dosyalarınınki, adları ne olursa olsun M48 başlığından) ve içe aktarmadan önce içe aktarma sayfasında değiştirilebilir: bir delme dosyası yeni bir delme programı olarak eklenir; diğer roller o yuvadaki dosyanın yerini alır. Kenar çubuğundaki bir katman dosyasına sağ tıklayarak **Replace…**, **Remove** ya da **Show in Finder** seçin.

## Tek bir programı dışa aktarma

Bir katman seçiliyken kenar çubuğundaki **CNC export → Export <ad>.ngc…** yalnızca o programı kaydeder — tam olarak önizlenen G-code, Generate'in yazacağı son işleme ve başlangıçla. Önizleme güncel olduğunda kullanılabilir. Yanındaki "X0 Y0 at" bağlantısı başlangıç ayarına atlar.

## Lazer kazıma ve çizim dışa aktarma

Uygulamanın ürettiği her program — bakır izolasyonu, dış hat, delikler, maske açıklıkları, serigrafi, özel katmanlar — bir lazer kazıyıcı için kartın gerçek fiziksel boyutunda çizim olarak dışa aktarılabilir: lazerin izleyebileceği vektör yollar (SVG, PDF) ya da bitmap (PNG). Tipik kullanımlar: kimyasal aşındırma için bakır üzerindeki boya ya da film maskesini açmak, maske kürlendikten sonra açıklıklarını yakarak temizlemek ve serigrafi yazılarını kazımak.

**Nerede.** Bir program seçiliyken kenar çubuğunun en altındaki **Laser export** bölümü yalnızca o programı dışa aktarır (**Export <ad>…**). Tüm programları bir kerede dışa aktarmak için **Generate → Produce: Laser artwork** kullanın; G-code yerine hedef klasöre program başına bir dosya yazar. Seçenekler iki yerde de aynıdır ve hatırlanır.

- **Format** — SVG ve PDF vektör kalır: takım yolu yollar olarak. PNG, seçilen **Resolution** değerinde (300, 600, 1000 ya da 2400 dpi) bir bitmap'tir; dpi dosyaya yazılır, böylece lazer yazılımı onu gerçek boyutuna yerleştirir. 1000 dpi, 0,15 mm'lik bir izi yaklaşık 6 piksele çözer. Üçü de kartın gerçek boyutunda çıkar.
- **Polarity** — *White on black*: kesim siyah zemin üzerinde beyazdır. *Black on white*: tersi. Zemin dosyaya çizilir; böylece polarite herhangi bir lazer programına içe aktarmada korunur.
- **Frame** — sayfanın kapsadığı alan. *Board*: bitmiş kart — kesim yolu yarım freze çapı içeri çekilir; 70 × 30 mm'lik bir kart, fiziksel PCB'ye hizalayabileceğiniz 70 × 30 mm'lik bir sayfa verir. *Origin*: X0/Y0'dan tüm programların en uzak köşesine kadar; dosyayı 0,0'a yerleştirmek onu tam frezenin keseceği yere koyar. *Project*: aynı ortak sayfa, programlara kırpılmış. *Layer*: yalnızca bu programın kendi kapsamı.
- **Takım genişliği** — View Options'ta **Tool Width** açıkken takım yolu freze çapında süpürülür, yani frezenin temizleyeceği bakır; kapalıyken yalnızca merkez çizgileri olarak dışa aktarılır. Hızlı hareketler hiçbir zaman dahil edilmez.

**Ablasyon için maske açıklıkları.** Solder mask → **Output: Laser SVGs**, maske frezeleme programlarını atlar ve bunun yerine açıklık şekillerinin kendilerini (pad'ler ve via'lar) gerbv aracılığıyla 1:1 SVG olarak dışa aktarır; kürlenmiş maskeyi parçaların lehimlendiği yerlerde yakıp açmaya hazırdır.

**Serigrafi.** Silkscreen → **Output: Engrave** yazıları bir programa dönüştürür (dolayısıyla çizim olarak dışa aktarılabilir); Output kapalıyken katman yok sayılır.

Çizimle ne yapacağınız sizin sürecinizdir; uygulama lazer G-code'u üretmez ve lazer gücünü ayarlamaz. Dosyayı seçtiğiniz Frame'e göre hizalayın: *Board*'u fiziksel kart kenarına, *Origin*'i frezeyi sıfırladığınız aynı X0 Y0'a.

## Özel katmanlar — kendi şekillerinizi çizme

**File → New Custom Layer** (⇧⌘N, kenar çubuğunun katman menüsünde de), üzerine çizim yaptığınız bir katman ekler: çizgiler ve çokgenler, dikdörtgenler (köşe yarıçapı ve döndürmeyle), daireler ve metin — yerleşik tek çizgili kazıma yazı tipiyle ya da kurulu herhangi bir yazı tipiyle, dış hatları boyunca kazınarak. Boş olmayan her katman bir program olur; Generate ve CNC dışa aktarma tarafından diğerleri gibi yazılır ve her düzenlemeden sonra yeniden üretilerek önizlemede gösterilir.

**Çizim.** Katman seçiliyken önizlemenin üzerinde araçların olduğu bir çubuk belirir — Select (V), Line (L), Rectangle (R), Circle (C), Text (T). Çizmek için tıklayın ya da sürükleyin; çift tık ya da Return bir çizgiyi bitirir, ilk noktasına tıklamak onu çokgen olarak kapatır; Shift 45°'ye kısıtlar ve kare yapar. Noktalar ızgaraya (Snap to Grid), kılavuzlara ve diğer şekillerin köşelerine, köşe noktalarına, merkezlerine ve çeyreklerine (Snap to Objects) yapışır; yeşil bir halka yapışmayı gösterir. Sağ ya da orta tuşla sürükleme kaydırır (Option-sürükleme de), kaydırma her zamanki gibi yakınlaştırır. Diğer programlar çizimin arkasında yalnızca All Layers Overlay açıkken görünür (View Options).

**Düzenleme.** Seçmek için tıklayın, eklemek için Shift-tık, bir kutu sürükleyin (sağa doğru: içinde kalan şekiller, sola doğru: dokunulan şekiller). Şekilleri taşımak için sürükleyin — birbirlerine yapışırlar — ya da dikdörtgen ve daireleri boyutlandırmak ve bir çizginin köşe noktalarını taşımak için tutamaçları sürükleyin. Ok tuşları 0,1 mm kaydırır (Shift: 1 mm), ⌘D çoğaltır, Delete siler, ⌘Z her şeyi geri alır. Kenar çubuğu şekilleri listeler; birini seçmek çizimin sağında, sayılarını içeren kayan bir Properties paneli açar — konum, boyut, köşe yarıçapı, döndürme, metin, yazı tipi, çizgi kalınlığı — tam değerler için; birkaçı seçiliyken **Align** (kenarlar ve merkezler) ve **Distribute** (eşit aralıklar) onları hizalar.

**İşleme.** Her katmanın bir takımı (kitaplıktan ya da elle girilmiş), bir derinliği, paso derinliği, ilerlemeleri ve iş mili ayarı ile bir işlemi vardır. *Engrave* takım merkezini çizilen çizgi boyunca yürütür; *Cut outside* / *Cut inside* kapalı şekilleri yarım takım kadar öteler; böylece çizdiğiniz, ortaya çıkan boyut olur (outside sakladığınız bir parça için, inside bir delik için). Takımdan geniş bir çizgi kalınlığı örtüşen pasolarla temizlenir; *Filled* kapalı bir şekli içten dışa boşaltır. Şekiller kart üzerinde tasarım koordinatlarında çizilir; bu yüzden seçtiğiniz başlangıç ne olursa olsun yerlerini korurlar ve Back tarafı katmanı arka bakır gibi aynalanır. Özel katmanlar projede kaydedilir.

## İçe aktarılmış katmanları düzenleme

İçe aktarılmış herhangi bir Gerber ya da delme dosyası yerinde düzenlenebilir: ondan üretilmiş bir programı seçip ayarlarının üstündeki **Edit**'e tıklayın ya da **Layer files** altındaki dosyaya sağ tıklayıp **Edit…** seçin. Dosyanın çizimi (pad'ler, izler, dolu alanlar ya da delikler) 2D görünümde programının üzerine çizilir.

- **Seç**: tıklayın, eklemek için ⇧-tık, kutu sürükleyin (soldan sağa içine alır, sağdan sola dokunur). ⌘A tümünü seçer; **Select Similar** (sihirli değnek) aynı genişlikteki her izi, aynı apertürlü pad'i ya da aynı boyuttaki deliği ekler.
- **Seçimin boyutlarını değiştir**: Properties panelinde iz genişliği, pad çapı ya da genişlik × yükseklik, delik çapı. Yalnızca seçili nesneler değişir.
- **Bir boyutu her yerde değiştir**: düzenlerken kenar çubuğu dosyanın apertürlerini (Gerber) ya da delme takımlarını (Excellon) listeler. Bir satırı düzenlemek onu kullanan her şeyi yeniden boyutlandırır, örneğin tüm 0,25 mm izleri bir kerede. Hedef simgesi onları seçer.
- **Taşı**: sürükleyerek ya da ok tuşlarıyla (0,1 mm, ⇧ 1 mm); **Sil**: ⌫ ile. Değerler Return ile onaylanır.

Her düzenleme dosyanın düzenlenmiş bir kopyasını yazar; asıl dosya asla değiştirilmez. Düzenlerken kenar çubuğu yalnızca dosyanın boyutlarını gösterir ve pcb2gcode çalışmaz — çizimin altındaki takım yolları düzenlemeden öncekilerdir. **Done**'a basın (ya da hiçbir şey seçili değilken Esc) ve önizleme düzenlenmiş dosyadan bir kez yeniden üretilir. Düzenlemeler normal geri alma geçmişindedir (⌘Z), düzenlenmiş dosyalar turuncu kalemle işaretlenir ve projeyi kaydetmek düzenlenmiş dosyayı paketler. Özel biçimli (makro) pad'ler ve dolu alanlar taşınabilir ya da silinebilir ama yeniden boyutlandırılamaz.

## Takım kitaplığı

**File → Tool Library…** (⇧⌘L), sahip olduğunuz her ucu kesme verileriyle birlikte tutar: biçim (düz / küresel / V uç), ne için kullanıldığı, çap ya da uç + açı, derinlik, paso derinliği (matkaplar: gagalama derinliği), ilerlemeler, iş mili, paso örtüşmesi ve matkaplar için delebileceği delik boyutu aralığı.

- **Import FlatCAM…**, bir FlatCAM Tools Database dışa aktarımını okur (Tools Database → Export, JSON `.TXT`). Tool Target, *Used for* ile eşleşir (Isolation, Drilling, Milling/Cutout → Cutout, diğerleri → General); V biçimi uç ve açıyı korur; FlatCAM'in delme toleransı delik aralığı olur. Yeniden içe aktarmak aynı addaki takımları çoğaltmak yerine günceller.
- Her takım gerçek oranlarıyla çizilir: listede bir profil simgesi ve düzenleyicinin üstünde ana ölçüleriyle yavaşça dönen bir 3D model (döndürmek için sürükleyin) — 3D önizlemenin kullandığı modelin aynısı.
- **Import…** / **Export…** kitaplığı bilgisayarlar arasında taşır: Export tüm kitaplığı `.json` olarak yazar; Import böyle bir dosyayı ya da bir FlatCAM Tools Database'i okur. Kitaplıkta zaten olan takımlar (aynı takım ya da aynı ad) güncellenir, kalanlar eklenir — böylece bir projenin "bits on hand" seçimi diğer makinede de eşleşir.
- Her ayar grubunun üstünde bir **Tool** menüsü vardır. Bir takım seçmek değerlerini gruba **kopyalar** — FlatCAM'in veritabanı verisini bir nesneye kopyalaması gibi — böylece katmanı yine ince ayarlayabilirsiniz. Alanlar artık takımla eşleşmediğinde **Edited** görünür; takımın değerlerini geri yüklemek için tıklayın. **Custom**, elle girilmiş değerler demektir.
- 0 olan ilerleme ya da iş mili (FlatCAM'in "ayarlanmamış" değeri) katmanın kendi değerini değiştirmez.

## Takım yolu motorları

Machine setup → **Toolpath engine**, Gerber ve delme dosyalarını programa dönüştüren şeyi seçer:

- **pcb2gcode** — yerleşik açık kaynak üretici. Uygulamanın içine gömülüdür (Contents/Helpers); kurulacak bir şey yoktur.
- **Native** — uygulamanın kendi motoru: dosyaları kendisi okur ve izolasyonu, tırnaklı dış hattı, delmeyi (eldeki uçlarla), delik frezelemeyi, lehim maskesi aşındırmasını ve serigrafiyi Clipper2 çokgen kitaplığıyla hesaplar. Uygulamanın içinde çalışır, bu yüzden daha hızlıdır ve pcb2gcode ile aynı kuralları izler — pasolar izolasyon genişliğine eşit dağıtılır, dış hattın merkez çizgisi kart kenarıdır, tırnaklar en uzun kenarlardadır.

İkisi de programlarını aynı biçimde yazar; dolayısıyla her ayar (beklemeler, gagalamalar, dalma boşluğu, ek kesim, yükseklikler, başlangıçlar) ikisine de uygulanır. Fark edebileceğiniz ayrımlar: yerel motor derinlikleri tam böler (0,6 mm'lik pasolarla 1,8 mm, 3 pasodur; pcb2gcode 0,45 mm'lik 4 paso yapar) ve yolları en yakın komşuya göre sıralar.

## Program üretme

**Generate** (araç çubuğu ya da kenar çubuğundaki Generate düğmesi) Generate iletişim kutusunu açar.

- **Produce** — *CNC G-code*, geçerli parametrelerle takım yollarını üretir ve `.ngc` programlarını yazar; tam olarak önizlemenin gösterdiği dosyalar. *Laser artwork* aynı programları üretir, sonra her birini G-code yerine lazer kazıyıcı için 1:1 çizim olarak yazar (`.ngc` dosyaları saklanmaz); Format, Polarity, Resolution ve Frame seçenekleri *Lazer kazıma ve çizim dışa aktarma* altında anlatılanlardır.
- **Destination** — dosyaların gideceği klasör; **Choose…** klasör seçiciyi açar (New Folder düğmesi yeni bir klasör oluşturur). Klasör yoksa oluşturulur ve aynı addaki mevcut dosyaların üzerine yazılır. Öneri, projenin yanındaki `Generated_GCode`'dur; seçim proje değiştirene kadar hatırlanır.
- Çalışırken iletişim kutusu aşamaları (ön bakır, arka bakır, dış hat, delme dosyası başına bir tane, maskeler, serigrafi, özel katmanlar) durumlarıyla listeler; **Cancel Run** o anda çalışan aşamadan sonra durur. Bitince **Open Folder** çıktıyı Finder'da gösterir ve Log sekmesinde aşama başına sürelerle tam çıktı bulunur.

**Çıktı dosyaları.** `front-copper.ngc`, `back-copper.ngc`, `outline.ngc`, delme dosyası başına bir `<delme dosyası>.ngc` (Mill large holes açıkken ayrıca `<delme dosyası>-milled.ngc`), `top-mask-etch.ngc` / `bottom-mask-etch.ngc`, `top-silkscreen.ngc` / `bottom-silkscreen.ngc` ve özel katman başına bir program. Arka taraf programları aynalanmıştır ve çevirdikten sonra çalışmaya hazırdır; tüm programlar Machine setup'ta seçilen başlangıcı paylaşır. Boşluk telafisi (Machine setup) bu dosyalara yazılırken uygulanır.

**More menüsü** (araç çubuğundaki …): **Open Output Folder** son hedefi gösterir; **Copy pcb2gcode Command** uygulamanın çalıştırdığı komut satırını tam olarak panoya koyar — pcb2gcode'u kendiniz çalıştırmak ya da bir hata bildirimi için; **New Custom Layer** ve **Generate Test Board…** File menüsündekilerle aynıdır.

## Parametreler

### Bakır izolasyonu
- **Tool diameter** — kesme derinliğindeki *etkin* çap (yukarıdaki "Takımlar ve V uçlar"a bakın) ya da **V-bit** seçip uç + açı girin.
- **Isolation width** — her izin çevresinde temizlenen toplam bakır; işleme süresi onunla neredeyse doğrusal büyür. Takım çapının 2–3 katı iyi bir başlangıçtır.
- **Cut depth** — bakır folyo ~0,035 mm'dir; −0,05…−0,08 mm payla keser. Daha derin, V uç kesimlerini genişletir ve izleri inceltir.
- **Depth per pass** — kesme derinliğine en fazla bu derinlikte birkaç eşit pasoyla ulaşın. 0 = tek paso.
- **Pass overlap** — komşu izolasyon pasoları arasındaki örtüşme (varsayılan %50).
- İzler asla kesilmez: ilk paso dışa doğru ötelenir; izolasyon yalnızca çevredeki fazla bakırı yer.

### Delme ve kesim
- **Her delme dosyasının kendi ayarları vardır.** Bir delme programını (ya da `… milled` programını) seçin; Drilling, Bits on hand, Hole milling ve Heights & direction grupları o dosyanın değerlerini gösterir — başlık dosyayı adlandırır. NPTH dosyası için Mill large holes'u açmak ya da via dosyasına daha sığ bir derinlik vermek diğer delme dosyaları için hiçbir şeyi değiştirmez. Projeye eklenen bir dosya delme varsayılanlarından başlar (hiçbir delme programı seçili değilken gösterilir) ve o andan sonra kendi değerlerini korur; dosyayla birlikte projede kaydedilirler. Bir preset uygulamak her delme dosyasını preset'in değerlerine getirir.
- Derinlikler = kart kalınlığı + feda tahtasına ~0,2 mm (1,6 mm malzeme → −1,8).
- **Peck depth** — gagalayarak delin: her gagalamadan sonra uç talaşı atmak için hızla çıkar, önceki dibin hemen üstüne döner ve ilerlemeyle devam eder. 0 = tek hamle.
- **Bits on hand** — sahip olduğunuz kitaplık matkaplarını işaretleyin. İşaretli bir ucun aralığındaki her delik o uçla delinir; böylece bir iş yalnızca o uçları gerektirir (0,915 mm'lik delik 1,0 mm'lik uca gider). Kendi aralığı olmayan uçlar **Bit tolerance**'ı kullanır (uç çevresinde ±). Hiçbir ucun kapsamadığı delikler tasarlanan boyutlarını korur ve Log onları adlandırır — aralıklar her zaman iletilir, çünkü onlarsız pcb2gcode *her* deliği en yakın uca yuvarlardı (3 mm'lik montaj deliği sessizce 1 mm delinirdi).
- **Hole milling** — sahip olduğunuz tüm matkaplardan büyük delikler için (örn. 2 mm 2 ağızlı mısır frezeyle 3–4 mm montaj delikleri). **Mill large holes**'u açın; **Mill holes from** ve üstündeki delikler delinmez, daire çizerek spiralle (helisel G2 hareketleri) kesilir; delme programının hemen ardından çalışan ayrı bir `… milled` programında. Delik frezeleme ucunun kendi Tool menüsü (kitaplıktan kesim ve genel takımlar), çapı, derinliği, paso derinliği (spiralin tur başına), ilerlemeleri, iş mili ve beklemesi vardır. Daire yarım uç kadar içe ötelenir; böylece delikler tasarlanan boyutta çıkar; uç, frezelenen en küçük delikten küçük olmalıdır.
- Kesim, **Pass depth** turlarıyla ilerler; süre = tur × çevre ÷ ilerleme.
- **Bridges**: Bridge Z'den derin pasolarda freze kalkar ve kartın son turda kopmaması için tutucu tırnaklar bırakır (önizlemede beyaz). Tırnak kalınlığı = kart altı − Bridge Z. İşlemeden sonra kırıp eğeleyin.

### Güvenlik yükseklikleri ve dalma boşluğu
- **Safe Z** — kesimler arasındaki hareket yüksekliği; mengeneleri ve kart eğriliğini aşmalıdır.
- **Plunge clearance** — dikey hareketler havada hızlıdır ve yalnızca bu yüksekliğin altında ilerlemeyle gider: inişler oraya kadar hızlı iner, sonra Z ilerlemesiyle dalar; çıkışlar oraya kadar ilerlemeyle çıkar, sonra hızlı gider. Bu çoğu zaman program süresini yarıya indirir (pcb2gcode tek başına tüm inişi — ve delme çıkışlarını da — ilerlemeyle yapar). Tipik 0,2–0,5 mm; kart eğriliğini aşmalıdır; 0 kapatır. Uç malzemeye her zaman programlanan ilerlemeyle girer ve çıkar.
- **Milling direction** (Machine setup) — Any, pcb2gcode'un en kısa yolu seçmesine izin verir; Climb ya da Conventional her frezeleme programı için sabitler (bu, 2-opt yol kısaltmayı kapatır, programlar biraz uzar).
- **Rapid feed** (Machine setup) — makinenizin G0 hızı, yalnızca süre tahminleri için kullanılır (FlatCAM'in FR Rapids'i).
- **Heights & direction** (her katman; ayrıca takım başına saklanır ve FlatCAM'den içe aktarılır) — katmanın kendi **Travel Z** ve **Tool-change Z** değerleri (takım değiştirme duraklaması ve program sonu yüksekliği; FlatCAM'in Tool-change Z / End Z'si); boş bırakılırsa alanda gri görünen Machine setup değerleri kullanılır; **Extra cut** (izolasyon, maske, serigrafi ve özel katmanlar) — her kapalı kontur, döngünün kapandığı yerde kıymık kalmasın diye başlangıcını bu uzunlukta geçer; pcb2gcode pasoları tek kesime zincirlediği yerde takım sonra oluk boyunca geri döner, böylece yalnızca zaten kesilmiş bakır yeniden kesilir; **Milling direction** — makine varsayılanı ya da bu katmanın kendisininki; **Spindle** — saat yönü (M3) ya da tersi (M4). Delik frezeleme delme yüksekliklerini kullanır (aynı pasoda çalışır).
- **Spindle dwell** (her katman, iş mili hızının yanında; ayrıca kitaplıkta takım başına saklanır ve FlatCAM'in beklemesinden içe aktarılır) — iş mili başladıktan sonra kesmeden önce hıza ulaşması için ve durduktan sonra takım değişiminden önce bekleme. 0 = bekleme yok. pcb2gcode beklemeleri milisaniye yazar (`G04 P2000`), ama GRBL ve LinuxCNC saniye okur; bu yüzden uygulama her programın beklemesini saniye olarak yazar (`G04 P2.000`). Milisaniye beklemeye ayarlı makineler (bazı Mach3 kurulumları) değerin ×1000'ine gerek duyar.

### Lehim maskesi aşındırma
`.GTS`/`.GBS` katmanları *açıklıkları* (açıkta kalan pad'ler/via'lar) tanımlar. CNC aşındırma modu katmanı tersine çevirir ve her açıklığı %40 örtüşen pasolarla boşaltır → `top-mask-etch.ngc` / `bottom-mask-etch.ngc`.
- Maske takımı en küçük açıklıktan büyük olmamalıdır (daha küçükler atlanır — Log'u izleyin).
- **Clear width** — her açıklığın içe doğru ne kadar boşaltılacağı. Varsayılan olarak (**Clear width from the mask layers** açık) uygulama maske dosyalarındaki en geniş açıklığı ölçer ve yarısı artı biraz fazlasını temizler; böylece her açıklık merkezine kadar temizlenir, daha geniş değil; alt bilgi en geniş açıklığı gösterir. Kapalıyken kendiniz girin: en geniş açıklığın yarısından ≥ olmalıdır, yoksa büyük açıklıkların ortası kapalı kalır; büyük değerler üretimi çok yavaşlatır.
- Aşındırma derinliğinin yalnızca kürlenmiş boyayı kaldırması gerekir, bakırı değil.

### Serigrafi kazıma
Serigrafi katmanları varsayılan olarak kapalıdır (kazımak üretim ve işleme süresine mal olur). **Output: Engrave** yazıların çizgilerini — referans adları, dış hatlar ve metin — kendileri frezeler; böylece karta kazınırlar: `top-silkscreen.ngc` / `bottom-silkscreen.ngc`, maskeden sonra en son çalıştırılır. Bölümün kendi takımı (düz ya da V uç), derinliği, **Clear width** değeri (takımdan geniş çizgiler örtüşen pasolarla temizlenir), paso örtüşmesi, ilerlemeleri ve iş mili vardır. Her iki durumda da bir program var olduğunda katman lazere dışa aktarılabilir.

### İlerlemeler, iş mili ve katman başına yükseklikler
Her ayar grubu **Feeds & spindle** — XY ilerlemesi, Z (dalma) ilerlemesi, iş mili hızı ve iş mili beklemesi — ve *Güvenlik yükseklikleri ve dalma boşluğu* altında anlatılan **Heights & direction** (Travel Z, Tool-change Z, Extra cut, Milling direction, iş mili yönü) ile biter. **Tool** menüsünden bir takım seçmek kitaplığın değerlerini gruba kopyalar; alanlar artık takımla eşleşmediğinde **Edited** görünür.

## Önizleme

### 3D görünüm

Önizlemenin üstündeki **2D / 3D** anahtarı programları 3D gösterir: kesimler her katmanın renginde çizgiler, kafa hareketleri kartın üstünde soluk sarı ve kesimden boyutlandırılmış yarı saydam 1,6 mm'lik bir FR4 levha. Yörüngede dönmek için sürükleyin, kaydırmak için sağ ya da orta tuşla (tekerlek) sürükleyin, yakınlaştırmak için kaydırın (fare tekerleği ya da iki parmak) ya da sıkıştırın.

- **Gizmo** (sağ üst): X/Y/Z topları görünümle döner; o eksen boyunca bakmak için birine tıklayın — Z = üst, −Z = alt, −Y = ön, Y = arka, X = sağ, −X = sol. Altında: tüm standart görünümlerin menüsü, **Iso**, **Fit**, perspektif/ortografik ve hareketler açık/kapalı.
- **All Layers Overlay** açıkken her program fiziksel kartın üzerine oturur: arka taraf programları alt yüzde aynalanmamış görünür; böylece arkayı incelemek için dönebilirsiniz. Tek program işlendiği gibi gösterilir.
- Oynatma 2D'deki gibi çalışır: programın biten kısmı vurgulanır ve **programı kesen uç** takımı gerçek boyutta izler — V ucun açısı ve ucuyla konisi, parmak frezenin ya da delik frezesinin çapı, 118° uçlu bir matkap; hepsi 1/8″ (3,175 mm), 38 mm'lik bir sapta PCB uçlarının taşıdığı renkli derinlik halkasıyla (sarı V uç, mavi parmak freze, kırmızı matkap, mor küresel uç). Program oynarken saat yönünde döner.

- Bir seferde bir program gösterilir (kenar çubuğunun üstündeki katman menüsü). Tüm programlar taraf başına bir başlangıç paylaşır; bu yüzden "All Layers Overlay" bakırı, delikleri ve maskeleri tam çakıştırır; aynalanmış arka tarafı önle hizalı bindirmek için "Un-mirror Back Side"ı açın.
- **Renkler**: kesimler için katman başına renkler; **sarı kesikli = kafa hareketi** (kesim yok); **beyaz = tutucu köprüler**; kesimlerin altındaki yarı saydam bant gerçek freze genişliğidir (View Options menüsündeki "Tool Width").
- **Un-mirror Back Side** (View Options menüsü), görsel hizalama kontrolleri için arka taraf programlarının aynalamasını kaldırır — yalnızca görüntüde; G-code aynalı ve CNC'ye hazır kalır. Kapalıyken arka taraf öne göre doğru biçimde aynalı durur.

### View Options
Önizlemenin üstündeki **View Options** menüsü görünümlerin neyi çizeceğini açıp kapatır: **Tool Width** (gerçek freze çapındaki yarı saydam bant; lazer dışa aktarımının süpürülmüş mü merkez çizgisi mi olacağına da karar verir), **Rulers**, **Guides** ve **Clear Guides**, **Snap to Grid** (⌘'), **All Layers Overlay**, **Un-mirror Back Side**, **abartma** ayarlı (×1 … ×50) **Height Map**, **Toolpath Lines**, **Drill Holes** (3D'de silindir olarak delikler), **Material Removal** (3D'de kesim kanalları ve bakır maskesi), **Machine Travel** (bağlı makinenin hareket alanı, kesikli) ve **Fit Machine Travel**.

**Kılavuzlar.** Rulers ve Guides açıkken bir cetvelden görünüme sürükleyerek bir kılavuz çizgisi çekin; taşımak için kılavuzu sürükleyin. Kılavuzlar çizimi, ölçümü ve başlangıç işaretini yapıştırır ve projeyle kaydedilir. Clear Guides hepsini kaldırır.

**Tuval düğmeleri** (2D görünümün sol üstü): yakınlaştır, uzaklaştır, sığdır (çift tık da aynısını yapar), tıklayarak başlangıcı ayarla, şerit metre ve başlangıca ortala.

## Oynatma ve tahminler

Kayan oynatıcı çubuğuyla ilerleme hızına sadık simülasyon: her hareket `uzunluk ÷ programlanan ilerleme` kadar sürer. **1× gerçek = %100 işleme hızı**; takım işareti hızlılar dahil her hareket boyunca kayar. G-code sekmesi geçerli kaynak satırını vurgular. Program başına süreler kenar çubuğunun katman menüsündedir; altındaki **Σ est.** toplamdır. Hızlılar 2000 mm/dk varsayılır (G-code hızlı ilerleme taşımaz).

## Yan görünüm

X–Z / Y–Z izdüşümleri ya da mesafeye göre Z **Profile**'ı; etiketli referans çizgileriyle (Z0, zwork, zdrill, zcut, zbridge, zsafe). Z abartılıdır (×N notu ne kadar olduğunu gösterir); zsafe üstündeki hareket, geri çekilmeler görünür kalsın diye ince bir üst banda sıkıştırılır.

## Görünüm denetimleri

Tekerlek / sıkıştırma = yakınlaştırma (imlece sabit) · sürükleme = kaydırma · çift tık / Fit düğmesi = sıfırlama. Yakınlaştırma ve kaydırma katman değişimlerinde korunur; panel ayırıcı konumları ve tüm parametreler açılışlar arasında kalıcıdır.

## Ölçme ve geri alma

**Ölçme.** 2D görünümün sağ üstündeki cetvel düğmesi (ya da görünüm odaktayken M) herhangi bir katmanda şerit metreyi açar. İki noktaya tıklayın — ya da aralarında sürükleyin — mesafe, ΔX, ΔY ve açıyı okuyun. Takım yolu köşelerine, deliklere, çizilen şekillere, başlangıca, kılavuzlara ve (Snap to Grid ile) ızgaraya yapışır; Shift çizgiyi yatay, dikey ya da 45°'de tutar. Esc ölçümü temizler, sonra araçtan çıkar.

**Geri alma.** Edit → Undo / Redo (⌘Z / ⇧⌘Z), tüm uygulama için tek bir geçmişte ilerler — parametre düzenlemeleri, uygulanan takımlar ve preset'ler, taşınan başlangıç, içe aktarılan, değiştirilen ya da kaldırılan katman dosyaları ve her çizim düzenlemesi. Başka bir proje açmak yeni bir geçmiş başlatır.

## G-code, Log ve Console sekmeleri

Önizlemenin üstündeki sekmeler ana alanı değiştirir:

- **Toolpath** — yukarıda anlatılan 2D/3D önizleme.
- **G-code** — seçili programın metni (üstteki **File** menüsü üretilmiş herhangi bir programı seçer). Oynatma sırasında ve bir program gönderilirken geçerli satır vurgulanır ve görünürde tutulur. 8 MB'tan büyük dosyaların ilk 8 MB'ı gösterilir.
- **Log** — pcb2gcode ve yerel motorun yazdığı her şey, adım adım ve süreleriyle; uyarılar `WARNING:`, hatalar `ERROR:` ile başlar ve hata en alttadır. pcb2gcode sürümü ve otomatik algılanan dosyalar bir proje açıldığında kaydedilir. Bir önizleme başarısız olduğunda önizleme bölmesi **Show Log** ve **Try Again** sunar.
- **Console** — makine konsolu: denetleyiciye gönderilen ve ondan alınan her satır. **Show status reports**, `?` sorgularını ve `<…>` raporlarını da gösterir (saniyede birkaç tane — tanılama için yararlı, yoksa gürültülü); **Clear** görünümü boşaltır. Komut alanı yazıldığı gibi bir satırı Return ile gönderir (`$G`, `G0 X10`, `$/axes/x/max_travel_mm`…); `!`, `~` ya da `?` gibi tek bir karakter gerçek zamanlı bayt olarak gönderilir; ↑ ve ↓ önceki komutları geri çağırır. Bir program çalışırken alan kilitlidir.

## Preset'ler ve ayarlar

**Presets** (araç çubuğu) eksiksiz parametre kümelerini — takımlar, ilerlemeler, derinlikler, yükseklikler, başlangıç — kaydeder ve geri çağırır; malzeme ya da makine başına kullanışlıdır. **Save Current as Preset…** geçerli değerleri adlandırır; bir preset seçmek onu uygular (ve her delme dosyasını preset'in delme ayarlarına getirir); **Delete Preset** birini siler. Preset uygulamak geri alınabilir.

**Settings (⌘,)** iki bölmeden oluşur:

### General
- **Language** — Sistem (macOS'u izler) ya da İngilizce, Fransızca, İspanyolca, Türkçe; arayüz ve yerleşik kılavuz için. Bir sonraki açılışta etkili olur. Kılavuz penceresinin kendi dil menüsü de vardır.
- **Units** — Metric (milimetre) ya da Imperial (inç). Okuduğunuz ve yazdığınız sayıları değiştirir: parametre alanları, cetveller, kılavuzlar ve oynatma okuması. Üretilen programlar her zaman metrik kalır (`G21`).
- **Preview refresh** — *Automatic*, parametre düzenlemelerinden sonra, **Delay after last edit** süresi boyunca yazmayı bıraktığınızda önizlemeyi yeniden üretir; *Manual* yalnızca Refresh düğmesiyle. "Out of date" rozeti her iki durumda da bayat bir önizlemeyi işaretler.

### Machine
- **Connection** — Transport (FluidNC için Wi‑Fi telnet, herhangi bir Grbl tipi denetleyici için USB seri ya da yerleşik Simulator), Host ve Port, seri port ve Baud (115200), durum sorgu aralığı (200 ms = saniyede 5 rapor), bağlantı koptuğunda otomatik yeniden bağlan, durum raporlarını konsolda göster, bağlantı seçicide Simulator'ı göster.
- **Jog** — panelin başladığı ilerleme ve adım ile uzun bir jog'u iptal edemeyen aygıt yazılımlarında sürekli jog için parça uzunluğu.
- **Z probe** — hızlı ve yavaş ilerlemeler, en fazla hareket, geri çekilme, plaka kalınlığı (Probe sekmesindeki değerlerin aynısı).
- **Motion** — Go to Work Zero için güvenli iş Z'si, hareket üst sınırının altındaki güvenli Z (takım değişimleri için park yüksekliği de), panelin Spindle düğmesi için en düşük ve en yüksek iş mili hızı, sürdürmeden önce iş mili ısınması.
- **Programs** — gönderirken boşluk telafisini uygula, takım değişiminden sonra devam etmeden önce onayla, bir program gönderildiğinde iş sıfırını kaydet (Positions sekmesinde programın adı ve saatle adlandırılmış bir Work girdisi; en yeni 20 otomatik girdi tutulur), akış penceresi (onaylanmamış kaç baytın yolda kalacağı; 0 = otomatik: USB seride 128, Wi‑Fi'de 512 ya da denetleyicinin bildirdiği alım tamponu — Wi‑Fi'de yaylar ve yuvarlak köşeler ilerlemeden yavaş gidiyorsa yükseltin, USB'deki bir Grbl kartını 128'de bırakın), yükseklik haritasının uygulandığı Z üst sınırı.
- **Axis calibration (steps/mm)** — Makine paneli altındaki *Eksen kalibrasyonu*'na bakın.

## Makine sıfırlama ve çift taraflı çalışma

**Machine setup → Origin → "X0 Y0 at"**, makine başlangıcının kart üzerinde nerede olduğuna karar verir; her program onu paylaşır, taraf başına bir başlangıç. Görünüm onu halkalı bir artı ve kırmızı X / yeşil Y oklarıyla işaretler (Fit her zaman çerçeveler).

- **Corners / Centre** — tüm projenin (tüm programların kapsamı), makinenin her tarafı gördüğü biçimiyle: çevirdikten sonra tezgâhın aynı köşesinde sıfırlarsınız.
- **Custom point** — tasarım (Gerber/EasyEDA) koordinatlarında bir nokta; takım boyutları onu asla kaydırmaz. İki tarafta da aynı fiziksel noktadır, örneğin bir hizalama deliği. Origin X / Y'yi yazın ya da görünümde ayarlayın (aşağıda).
- **Görünümde taşıma** — başlangıç işaretini X0 Y0'ın olması gereken yere sürükleyin ya da **Set Origin in View**'a (Machine setup) / nişangâh düğmesine tıklayıp noktaya tıklayın. İkisi de projenin köşelerine ve merkezine (bu, o köşe modunu ayarlar) ve deliklere (özel nokta) yapışır. **Snap to Grid** açıkken (View Options ya da View → Snap to Grid, ⌘') diğer bırakmalar görünümde gösterilen ızgaraya düşer; böylece başlangıç tam ızgara adımlarıyla hareket eder; daha ince ızgara için yakınlaştırın.
- **Design origin** — sıfırlama yok; koordinatlar tam dışa aktarıldığı gibi.

Ön taraf programları (bakır, delikler, dış hat, üst maske) için X/Y'yi başlangıçta sıfırlayın, sonra arka taraf programları için çevirdikten sonra bir kez daha — her şey çakışık kalır. Z'yi kart yüzeyinde sıfırlayın. Çevirme yönünü **Mirror around Y axis** ile seçin ve Flip Back View ile doğrulayın. Problama ve yükseklik haritaları Makine panelinden canlı yapılır (aşağıda); programların kendileri düz G-code kalır.

## Boşluk telafisi

GRBL ve FluidNC'de boşluk ayarı yoktur; bu yüzden uygulama X ve Y eksenlerindeki boşluğu kendisi telafi edebilir. **Machine setup → Backlash compensation** eksen başına boşluğu tutar (boşluk test kartıyla ölçün). Değerler projeye değil makineye aittir: uygulama genelindedir ve `.cncproj` dosyalarına kaydedilmez.

- Bir değer ayarlıyken uygulamanın yazdığı her program — Generate, CNC dışa aktarma, test kartları — yeniden yazılır: eksi yönde giderken ulaşılan koordinatlar boşluk kadar kaydırılır, eksenin yön değiştirdiği her yere yalnızca o eksenin kısa bir boşluk alma hareketi eklenir, yaylar X/Y uç noktalarında bölünür ve ilk hızlı hareket aşağıdan bir giriş alır. Önizleme ve G-code sekmesi her zaman telafisiz programı gösterir.
- **Compensate a G-code File…**, bu uygulamanın dışında yapılmış bir programın telafi edilmiş kopyasını yazar.
- Makine panelinden gönderirken Program sekmesindeki **Backlash compensation** anahtarı (varsayılanı Settings → Machine → *Apply backlash compensation when sending*) akıtılan kopyayı yeniden yazar; diskteki dosyalara dokunulmaz.
- G91 (göreli hareketler), G20 (inç), R biçimli yaylar, G28/G53/G92 ya da hazır çevrimler içeren programlar Log'da bir WARNING ile telafisiz bırakılır.
- Makine onarıldığında değerleri 0'a geri alın — boşluğu mekanik olarak gidermek her zaman daha iyidir.

## Makine paneli

Araç çubuğundaki **Machine** düğmesi (View → Machine Panel, ⇧⌘M) ana pencerenin sağında bir panel açar: GRBL 1.1 ve FluidNC denetleyicileri için yerel bir gönderici. Bağlantı şeridi ve konum göstergesi üstte kalır; alttaki sekmeler (Control, Positions, Program, Probe, Height Map, Macros) kendi başlarına kayar; göstergenin altındaki kırmızı **E-STOP** her sekmede görünür kalır; konsol ana pencerenin Console sekmesidir ve panelin üstündeki "Open in a window" aynı denetimlere program metniyle birlikte kendi pencerelerini verir.

### Bağlanma
**Wi‑Fi** (denetleyicinin IP'si ve telnet portu, varsayılan 23) ya da **USB** (115200'de bir `/dev/cu.*` portu) seçip Connect'e basın. Durum kapsülü Idle / Run / Jog / Hold / Alarm… gösterir, rozet uygulamanın tanıdığı aygıt yazılımını (`$I`), alarmlar Unlock / Home / Reset ile çözülmüş olarak görünür. Konumu kaybettiren alarmlar (sınırlar, hareket sırasında reset) konumu güvenilmez işaretler: Home yapın ya da konumu olduğu gibi tutmak için Unlock'a basın. Bağlantı diğer istemcilerle birlikte çalışır (aynı denetleyicideki bir kumanda çalışmaya devam eder).

### DRO, sıfırlama, konumlar
İş ve makine koordinatları, canlı ilerleme ve iş mili, planlayıcı tamponu ve tetiklenen pinler (P = prob girişi kapalı). O ekseni ayarlamak ya da sıfırlamak için bir eksen değerine tıklayın; altındaki düğme ızgarasının ilk satırında **Zero XY / Zero Z / Zero All** (`G10 L20 P0`, kalıcı) ve **Probe Z** (Probe sekmesinin iki geçişli dokunması), ikinci satırında **Work Zero** (önce güvenli iş Z'sine çekilir), **Safe Z** (Z hareket üst sınırının hemen altı), **Home** ve **Unlock** vardır. **Positions** sekmesi adlı makine konumlarını tutar; **Go to coordinates…** yazılan bir makine hedefine gider (yükselirken önce Z, inerken en son). **Save work zero**, iş X0 Y0 Z0'ının makine koordinatlarında nerede olduğunu saklar ve herhangi bir girdideki **Use as zero** iş başlangıcını o noktada yeniden kurar (`G10 L2 P0`, hareket yok) — bir reset ya da yeniden home'dan sonra sıfırı geri getirir. Control sekmesindeki **User buttons**, Macros sekmesinin makrolarını çalıştırır (makro başına bir düğme, isteğe bağlı SF Symbol simgesi; "allow while running" bir düğmeyi iş sırasında etkin tutar, soğutma sıvısı gibi kısa komutlar için). **E-STOP** (iş çubuğunun sonunda ve ⇧⌘. ile de) jog iptali, feed hold ve soft reset'i hiçbir şeyi beklemeden tek seferde gönderir; makine hareket ediyorduysa konum güvenilmez işaretlenir. ⌘. kontrollü durdurma olarak kalır.

### Jog ve override'lar
Tek adım için bir jog düğmesine dokunun; bırakınca duran sürekli hareket için basılı tutun (yazılım sınırları olan home'lanmış bir FluidNC'de jog sınıra kadar gider ve bırakınca iptal edilir; aksi halde kısa parçalar akıtılır). Çapraz düğmeler iki ekseni hareket ettirir. **Klavye jog**: oklar = X/Y, Page Up/Down = Z, Shift = adım ×10, Esc ya da ⌘. = dur. Override'lar ilerlemeyi (%10–200, 1 ve 10'luk adımlarla), hızlıları (%25/50/100) ve iş mili hızını gerçek zamanlı ayarlar; denetleyici kullandığı değeri bildirir.

**Makine denetimleri** (Control sekmesi): **Reset** (Ctrl‑X soft reset — her şeyi durdurur; makine hareket ediyorduysa konum kaybolur), **Hold** / **Resume** (feed hold, cycle start), **Check** (`$C` — G-code ayrıştırılır ama hiçbir şey hareket etmez), yanındaki devirde **Spindle** açık/kapalı (Settings → Machine'deki en düşük ve en yükseğe sınırlanır), **Coolant** (M8/M9) ve More altında: **Sleep**, **Safety Door** ve yanıtları Console'da görünen `$G` (ayrıştırıcı durumu), `$#` (ofsetler) ve `$I` (derleme bilgisi) sorguları.

### Positions sekmesi
**Machine / Work** anahtarıyla seçilen iki listede adlı makine konumları. **Machine** iş milinin geri döndüğü noktaları tutar: **Save current…** iş milinin şu an bulunduğu makine koordinatlarını saklar, **Go to…** yazılan bir makine koordinatına gider ve her girdide **Go** vardır (yükselirken önce Z, inerken en son, jog ilerlemesinde). **Work** iş sıfırlarını tutar — iş X0 Y0 Z0'ının makine koordinatlarında nerede olduğu: **Save work zero** geçerli olanı elle saklar; *Save the work zero when a program is sent* (Ayarlar → Machine, varsayılan olarak açık) ile her gönderim, programın adı ve saatle adlandırılmış bir girdiyi otomatik kaydeder ("Front copper – 8 Oct 14:07", saat simgesi). Bir Work girdisinde **Use as zero** o noktayı `G10 L2` ile yeniden iş başlangıcı yapar — makine hareket etmez — böylece bir çarpma, reset ya da home'dan sonra aynı sıfır yeniden dokunma gerekmeden geri gelir. Bir girdiye sağ tıklayın: **Rename…**, **Overwrite with Current Position** / **Current Work Zero**, diğer listeye ait **Go There…** / **Use as Work Zero…** ve **Delete**. Makrolar `@goto <ad>` ile kayıtlı bir konuma gidebilir.

### Program sekmesi — gönderme
Üretilmiş bir katman seçin (ya da kenar çubuğunda CNC export → **Send … to Machine…**) ya da dış bir program için (örneğin bir test kartı) **Open .ngc file…**. **Backlash** ve **Apply height map** gönderilen kopyayı dönüştürür, diskteki dosyaları asla; **Save sent program…** o kopyayı saklar. **Verify** programı hareketsiz, check modunda akıtır. Makinenin hareket alanı programı sığdıramıyorsa iş çubuğu bunu açıkça söyler — örneğin iş Z0'ı üst sınıra yakın olduğundan 12. satırın hareket üst sınırının üstünde bir Z'ye yükseldiğini; tek sorun buysa **Clamp Z to top** programı o geri çekilme yüksekliklerini üst sınırın hemen altına indirerek yeniden hazırlar (kesme derinliklerine dokunulmaz; açıkken turuncu bir "Z clamped" rozeti görünür), böylece boşta bir deneme yapılabilir. **Send** karakter sayımıyla akıtır; ana pencerenin tuvalleri, yan görünüm, 3D görünüm ve G-code sekmesi işi izler, mavi bir artı makinenin gerçek konumunu işaretler ve iş çubuğu satırı, geçen ve kalan süreyi gösterir. Hold/Resume ve override'lar canlı kalır. **Stop** hold yapar, makine durunca reset atar ve iş milini kapatır.

Takım değişimleri (ek matkap boyutları) işi değişimden önce askıya alır: iş mili kapalı, Z üstte park, ve bir afiş ucu adlandırır. Askıdayken Jog, Zero ve **Probe Z** etkindir; böylece yeni ucu dokundurabilirsiniz, ardından hemen süren **Continue** — afiş göndereceği başlangıç satırlarını listeler (Settings → Machine → *Confirm before continuing after a tool change* onay sayfasını geri getirir). **Send from line…**, programın ortasından güvenli bir başlangıçla (geri çekilme, iş mili, noktanın üstüne hızlı, dalma) sürdürür; her zaman onay için gösterilir. Bir iş çalışırken uygulama proje değiştirmeden, bağlantıyı kesmeden ya da çıkmadan önce sorar.

### Probe sekmesi
İki geçişli bir Z dokunması: temas bulana kadar hızlı iniş, 1 mm geri, tam nokta için yavaş iniş; etkin iş başlangıcı sonra temas noktasına ayarlanır (`G10 L20`; yavaş geçiş tetiklemenin bir mikron yakınında durur) ve denetleyiciden geri okunur — DRO daha sonra geri çekilme yüksekliğini, yüzeyde Z0 ile gösterir. Plaka kalınlığı 0 = bakıra kıskaç ve prob olarak uç; dokunma plakası için kalınlığı girin. Settings → Machine ilerlemeleri, en fazla hareketi ve geri çekilmeyi tutar.

### Eksen kalibrasyonu (adım/mm)

10 mm'lik bir jog iş milini 9,85 mm hareket ettiriyorsa denetleyicinin adım/mm değeri yanlıştır. Settings → Machine → **Axis calibration** (FluidNC, bağlıyken) denetleyiciden `axes/x|y/steps_per_mm` değerini ve yapılandırma dosyasının adını okur. Bir komparatör ya da cetvelle ölçün: önce ölçüm yönünde biraz jog yapın (boşluğu alır), komparatörü sıfırlayın, bilinen bir mesafe jog yapın — ne kadar uzun o kadar iyi — ve komut verilen ile ölçüleni girin; yeni adım/mm = geçerli × komut verilen ÷ ölçülen. **Apply** çalışan yapılandırmayı hemen yazar (`$/axes/x/steps_per_mm=…`) ve kaydetme anahtarı açıkken `$CD=<yapılandırma dosyası>` o dosyayı (örn. `raptorex.yaml`) çalışan yapılandırmadan yeniden yazar; böylece değer yeniden başlatmada korunur. Sonra yeniden ölçün; birkaç yüzde birden fazla ayrışan ölçümler adım/mm'yi değil boşluğu ya da gevşek bir kasnağı işaret eder.

### Macros sekmesi
Kendi komut dizileriniz. **Add**, bir ad, isteğe bağlı bir SF Symbol simgesi (`fan.fill`, `drop.fill`, `house`…) ve gönderdiği G-code satırlarıyla bir makro oluşturur; **Run** satırları her birinin onayını bekleyerek sırayla gönderir (makine bağlı ve boşta olmalıdır); **Edit**, sağ tıkla **Duplicate** ve **Delete**; **Restore Defaults** listeyi yerleşik örneklerle değiştirir. Her makro Control sekmesinde bir **user button**'dır da; *allow while running* bir düğmeyi iş sırasında etkin tutar, soğutma sıvısı gibi kısa komutlar için. Bir satırdaki `@goto <konum>` Positions sekmesindeki kayıtlı bir konuma gider.

### Height Map sekmesi
Kart üzerinde bir ızgara tanımlayın (**Auto** seçili programa sığdırır), **Probe** ile problayın ve sapmayı okuyun. Haritalar taraf başınadır ve iş başlangıcında problanan Z'ye göre saklanır; bu yüzden takım değişiminden sonra orada Z'yi yeniden problamak onları geçerli tutar. **Apply height map** açıkken akıtılan kopyanın her kesimi ve alçak dalışı ölçülen yüzeye göre bükülür (çift doğrusal ara değerleme); güvenli yükseklikteki hızlılara dokunulmaz. Problamadan bu yana iş başlangıcı taşındıysa uygulama uygulamadan önce uyarır. Haritalar proje başına Application Support altında tutulur ve JSON olarak kaydedilip yüklenebilir; View Options → Height Map noktaları takım yolunun üzerinde gösterir.

### Makinesiz deneme
Settings → Machine'de **Show the Simulator in the connection picker**'ı açın, bağlantı çubuğunda **Simulator**'ı seçip Connect'e basın: uygulama özel bir portta yerleşik bir FluidNC simülatörü (`fake-grbl.py`, paketli; Xcode komut satırı araçlarındaki python3'ü gerektirir) başlatır ve onunla gerçek bir denetleyici gibi konuşur — gerçek zamanlı hareket, alarmlar, takım değişimi askıya almaları, iş sıfırının 1 mm altındaki yapay yüzeye karşı Z problama, yükseklik haritaları. İş sıfırı örnek programlar hareket alanına sığsın diye önceden ayarlıdır. Durum kapsülü bir **SIM** etiketi taşır ve rozet Simulator yazar; Disconnect ya da çıkmak onu durdurur. (Geliştirme: `-debugMachineWindow 1 -debugMachineConnect sim`.)

## Sorun giderme

- **pcb2gcode eksik** → yalnızca onsuz yapılmış derlemelerde; yerel motor devralır (Machine setup → Toolpath engine). Normal derlemeler pcb2gcode'u uygulamanın içinde taşır — kurulacak bir şey yok.
- **Önizleme başarısız** → Log sekmesinde adım başına sürelerle tam çıktı var; hata en altta.
- **Yakın izler arasında kesilmemiş boşluklar** → takım sığmayacak kadar geniş; pcb2gcode Log'da uyarır. Etkin takım çapını küçültün ya da tasarım aralığını büyütün.
- **Maske açıklığı temizlenmedi** → açıklık maske takımından küçük ya da elle girilen Clear width < açıklığın yarısı ("Clear width from the mask layers"ı yeniden açın).
- **Yavaş üretim** → maske Clear width çok büyük ya da izolasyon genişliği çok geniş.

## Klavye kısayolları

| Eylem | Tuşlar |
|---|---|
| New Project / Open Project… / Open Gerber Folder… | ⌘N / ⌘O / ⇧⌘O |
| Save Project / Save Project As… | ⌘S / ⇧⌘S |
| Import Layer… / New Custom Layer | ⌘I / ⇧⌘N |
| Generate Test Board… / Tool Library… | ⇧⌘T / ⇧⌘L |
| Geri al / Yinele | ⌘Z / ⇧⌘Z |
| Tüm şekilleri seç / Şekilleri çoğalt | ⇧⌘A / ⌘D |
| Snap to Grid | ⌘' |
| Makine paneli / Acil durdurma | ⇧⌘M / ⇧⌘. |
| Ayarlar / Yardım | ⌘, / ⌘? |
| Çizim araçları (özel katman, görünüm odakta) | V seç · L çizgi · R dikdörtgen · C daire · T metin |
| Şerit metre / araçtan çık | M / Esc |
| Seçili şekilleri kaydır | Oklar 0,1 mm · ⇧Oklar 1 mm |
| Makine jog (Keyboard jog açık) | Oklar X/Y · Page Up/Down Z · ⇧ adım ×10 · Esc ya da ⌘. dur |
| Konsol geçmişi | ↑ / ↓ |
