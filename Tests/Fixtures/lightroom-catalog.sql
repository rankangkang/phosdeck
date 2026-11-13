CREATE TABLE AgLibraryRootFolder (id_local INTEGER PRIMARY KEY, absolutePath TEXT, relativePathFromCatalog TEXT, name TEXT);
CREATE TABLE AgLibraryFolder (id_local INTEGER PRIMARY KEY, rootFolder INTEGER, pathFromRoot TEXT);
CREATE TABLE AgLibraryFile (id_local INTEGER PRIMARY KEY, folder INTEGER, idx_filename TEXT);
CREATE TABLE Adobe_images (id_local INTEGER PRIMARY KEY, rootFile INTEGER, masterImage INTEGER, copyName TEXT, rating INTEGER, pick INTEGER, colorLabels TEXT, captureTime TEXT, orientation TEXT, fileWidth INTEGER, fileHeight INTEGER);
CREATE TABLE Adobe_imageDevelopSettings (image INTEGER, text TEXT);
CREATE TABLE AgLibraryKeyword (id_local INTEGER PRIMARY KEY, name TEXT, parent INTEGER);
CREATE TABLE AgLibraryKeywordImage (image INTEGER, tag INTEGER);
CREATE TABLE AgLibraryCollection (id_local INTEGER PRIMARY KEY, parent INTEGER, creationId TEXT, name TEXT, systemOnly INTEGER);
CREATE TABLE AgLibraryCollectionImage (collection INTEGER, image INTEGER, positionInCollection TEXT);
CREATE TABLE AgHarvestedIptcMetadata (image INTEGER, caption TEXT);
CREATE TABLE Adobe_libraryImageDevelopHistoryStep (image INTEGER, text TEXT);

INSERT INTO AgLibraryFolder VALUES (1,1,'2026/拍摄/');
INSERT INTO AgLibraryFile VALUES (1,1,'A.jpg'), (2,1,'Missing.jpg'), (3,1,'Movie.mov'), (4,1,'B.jpg');
INSERT INTO Adobe_images VALUES (1,1,NULL,'',5,1,'Green','2026-11-13T09:30:00','AB',20,10),
    (2,1,1,'Mono',2,-1,'Red',NULL,'BC',20,10),
    (3,2,NULL,'',4,0,'',NULL,'AB',20,10), (4,3,NULL,'',0,0,'',NULL,'AB',20,10),
    (5,4,NULL,'',0,0,'',NULL,'AB',20,10);
INSERT INTO Adobe_imageDevelopSettings VALUES (1,'s = { Exposure2012 = 0.75, CameraProfile = "Adobe Color", CropLeft = 0.25, CropRight = 0.75, CropTop = 0.1, CropBottom = 0.7, }'),
    (2,'return { ConvertToGrayscale = true, Exposure2012 = -0.5 }');
INSERT INTO AgLibraryKeyword VALUES (1,'旅行',NULL), (2,'云南',1);
INSERT INTO AgLibraryKeywordImage VALUES (1,2);
INSERT INTO AgLibraryCollection VALUES (1,NULL,'collection.group','2026',0), (2,1,'collection','Keepers',0), (3,NULL,'collection.smart','Stars',0);
INSERT INTO AgLibraryCollectionImage VALUES (2,1,'b'), (2,2,'a'), (2,3,'c');
INSERT INTO AgHarvestedIptcMetadata VALUES (1,'Mountains');
INSERT INTO Adobe_libraryImageDevelopHistoryStep VALUES (1,'s = { Exposure2012 = 0.2 }');
