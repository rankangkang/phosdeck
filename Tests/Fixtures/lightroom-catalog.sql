CREATE TABLE AgLibraryRootFolder (id_local INTEGER PRIMARY KEY, absolutePath TEXT, relativePathFromCatalog TEXT, name TEXT);
CREATE TABLE AgLibraryFolder (id_local INTEGER PRIMARY KEY, rootFolder INTEGER, pathFromRoot TEXT);
CREATE TABLE AgLibraryFile (id_local INTEGER PRIMARY KEY, folder INTEGER, idx_filename TEXT);
CREATE TABLE Adobe_images (id_local INTEGER PRIMARY KEY, rootFile INTEGER, masterImage INTEGER, copyName TEXT, rating INTEGER, pick INTEGER, colorLabels TEXT, captureTime TEXT, orientation TEXT, fileWidth INTEGER, fileHeight INTEGER);
CREATE TABLE Adobe_imageDevelopSettings (image INTEGER, text TEXT, historySettingsID INTEGER);
CREATE TABLE AgLibraryKeyword (id_local INTEGER PRIMARY KEY, name TEXT, parent INTEGER);
CREATE TABLE AgLibraryKeywordImage (image INTEGER, tag INTEGER);
CREATE TABLE AgLibraryCollection (id_local INTEGER PRIMARY KEY, parent INTEGER, creationId TEXT, name TEXT, systemOnly INTEGER);
CREATE TABLE AgLibraryCollectionImage (collection INTEGER, image INTEGER, positionInCollection TEXT);
CREATE TABLE AgHarvestedIptcMetadata (image INTEGER, caption TEXT);
CREATE TABLE Adobe_libraryImageDevelopHistoryStep (id_local INTEGER PRIMARY KEY, image INTEGER, name TEXT, dateCreated DOUBLE, text);
CREATE INDEX history_by_image ON Adobe_libraryImageDevelopHistoryStep (image, dateCreated);

INSERT INTO AgLibraryFolder VALUES (1,1,'2026/拍摄/');
INSERT INTO AgLibraryFile VALUES (1,1,'A.jpg'), (2,1,'Missing.jpg'), (3,1,'Movie.mov'), (4,1,'B.jpg');
INSERT INTO Adobe_images VALUES (1,1,NULL,'',5,1,'Green','2026-11-13T09:30:00','AB',20,10),
    (2,1,1,'Mono',2,-1,'Red',NULL,'BC',20,10),
    (3,2,NULL,'',4,0,'',NULL,'AB',20,10), (4,3,NULL,'',0,0,'',NULL,'AB',20,10),
    (5,4,NULL,'',0,0,'',NULL,'AB',20,10);
INSERT INTO Adobe_imageDevelopSettings VALUES (1,'s = { Exposure2012 = 0.75, CameraProfile = "Adobe Color", CropLeft = 0.25, CropRight = 0.75, CropTop = 0.1, CropBottom = 0.7, }',11),
    (2,'return { ConvertToGrayscale = true, Exposure2012 = -0.5 }',NULL);
INSERT INTO AgLibraryKeyword VALUES (1,'旅行',NULL), (2,'云南',1);
INSERT INTO AgLibraryKeywordImage VALUES (1,2);
INSERT INTO AgLibraryCollection VALUES (1,NULL,'collection.group','2026',0), (2,1,'collection','Keepers',0), (3,NULL,'collection.smart','Stars',0);
INSERT INTO AgLibraryCollectionImage VALUES (2,1,'b'), (2,2,'a'), (2,3,'c');
INSERT INTO AgHarvestedIptcMetadata VALUES (1,'Mountains');
INSERT INTO Adobe_libraryImageDevelopHistoryStep VALUES
    (12,1,'Latest exposure',4000,'s = { Exposure2012 = 1.5 }'),
    (10,1,'First exposure',1000,X'0000004b789c2b56b055a85670ad28c82f2e2d4a35323034020a18e819e9283817e51738e6a5e7a402050c0d217c9fd4b41298bc4762314808c84d4bcc294e55a80500368515f8'),
    (11,1,'Cropped exposure',2000,'s = { Exposure2012 = 0.75, CropLeft = 0.25, CropRight = 0.75, CropTop = 0.1, CropBottom = 0.7 }'),
    (13,1,'Unreadable step',3000,X'00000020789c'),
    (20,2,'Copy exposure',2100,'s = { Exposure2012 = -0.2, Orientation = "AB" }');
