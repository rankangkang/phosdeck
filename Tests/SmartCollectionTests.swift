import XCTest
import GRDB
@testable import Phosdeck

final class SmartCollectionTests:XCTestCase {
    private func fixture(_ count:Int = 405) throws -> (URL,CatalogStore,StorageRoot) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let catalog = try CatalogStore(directory:folder), root = try catalog.addRoot(url:folder,bookmark:Data())
        try catalog.database.write { db in
            for i in 0..<count {
                let metadata = try JSONEncoder().encode(PhotoMetadata(lens:i % 2 == 0 ? "Prime" : nil,iso:i % 2 == 0 ? 400 : nil))
                try Photo(id:String(format:"%05d",i),rootID:root.id,relativePath:"folder/IMG_\(i).jpg",identity:Data(),identityKey:"fixture-\(i)",rating:i % 6,flag:i % 3-1,captureDate:i % 2 == 0 ? "2024:02:29 12:00:00" : nil,width:10,height:10,camera:i % 2 == 0 ? "Camera" : nil,metadata:metadata).insert(db)
            }
        }
        return (folder,catalog,root)
    }
    private func save(_ rules:SmartRules,id:String = "s",catalog:CatalogStore) throws -> PhotoCollection {
        let value = try PhotoCollection(id:id,name:"Smart",rules:JSONEncoder().encode(rules))
        _ = try catalog.replaceSmartCollection(id:id,with:value); return value
    }

    func testSmartRulesFromFlagSetKeepsSingleExclusionAndAllStates() throws {
        let picked = try SmartRules.from(PhotoQuery(flags: [1]))
        let pickedRule = try XCTUnwrap(picked.conditions.first { $0.field == .flag })
        XCTAssertEqual(pickedRule.op, .equal)
        XCTAssertEqual(pickedRule.value, "1")

        let pickedOrUnflagged = try SmartRules.from(PhotoQuery(flags: [1, 0]))
        let exclusion = try XCTUnwrap(pickedOrUnflagged.conditions.first { $0.field == .flag })
        XCTAssertEqual(exclusion.op, .notEqual)
        XCTAssertEqual(exclusion.value, "-1", "Two selected states are represented by excluding the third")

        let allStates = try SmartRules.from(PhotoQuery(flags: [-1, 0, 1]))
        XCTAssertFalse(allStates.conditions.contains { $0.field == .flag }, "Selecting every state must not add a redundant rule")

        let unrestricted = try SmartRules.from(PhotoQuery(flags: []))
        XCTAssertFalse(unrestricted.conditions.contains { $0.field == .flag }, "An empty state set means no flag constraint")
    }

    func testTypedRulesNullsRangesBindingAndStrictValidation() throws {
        let (folder,catalog,root) = try fixture(12); defer { try? FileManager.default.removeItem(at:folder) }
        _ = try catalog.changeKeyword("Travel",ids:["00000","00001"],adding:true)
        for field in SmartField.allCases {
            let rule:SmartRule
            switch field {
            case .filename:rule = SmartRule(field:field,op:.contains,value:"IMG_0")
            case .rating:rule = SmartRule(field:field,op:.between,value:"3",upper:"5")
            case .flag:rule = SmartRule(field:field,op:.equal,value:"1")
            case .colorLabel:rule = SmartRule(field:field,op:.equal,value:"0")
            case .keyword:rule = SmartRule(field:field,op:.equal,value:"travel")
            case .camera:rule = SmartRule(field:field,op:.contains,value:"cam")
            case .lens:rule = SmartRule(field:field,op:.equal,value:"Prime")
            case .iso:rule = SmartRule(field:field,op:.between,value:"200",upper:"800")
            case .captureDate:rule = SmartRule(field:field,op:.between,value:"2024-02-29",upper:"2024-03-01")
            case .virtualCopy:rule = SmartRule(field:field,op:.equal,value:"false")
            case .copyName:rule = SmartRule(field:field,op:.empty)
            }
            let rules = SmartRules(source:root.id,conditions:[rule])
            _ = try save(rules,catalog:catalog)
            XCTAssertGreaterThan(try catalog.collectionCount(XCTUnwrap(catalog.collections().first)),0,"\(field)")
        }
        for field in [SmartField.iso,.lens,.camera,.captureDate] {
            _ = try save(SmartRules(conditions:[SmartRule(field:field,op:.empty)]),catalog:catalog)
            XCTAssertEqual(try catalog.members("s").count,6)
        }
        _ = try save(SmartRules(conditions:[SmartRule(field:.filename,op:.contains,value:"%' OR 1=1 --")]),catalog:catalog)
        XCTAssertTrue(try catalog.members("s").isEmpty)
        for rule in [SmartRule(field:.rating,op:.equal,value:"6"),SmartRule(field:.rating,op:.equal,value:"1.2"),SmartRule(field:.iso,op:.equal,value:"nan"),SmartRule(field:.iso,op:.between,value:"800",upper:"100"),SmartRule(field:.virtualCopy,op:.contains,value:"true"),SmartRule(field:.virtualCopy,op:.equal,value:"1"),SmartRule(field:.captureDate,op:.equal,value:"2025-02-29"),SmartRule(field:.captureDate,op:.between,value:"2024-04-01",upper:"2024-03-01"),SmartRule(field:.keyword,op:.contains,value:"")] {
            XCTAssertThrowsError(try rule.validate())
        }
        XCTAssertThrowsError(try SmartRules(conditions:[]).validate())
        XCTAssertThrowsError(try SmartRules(conditions:Array(repeating:SmartRule(),count:33)).validate())
        XCTAssertThrowsError(try save(SmartRules(source:"collection:s"),id:"recursive",catalog:catalog))
        XCTAssertThrowsError(try JSONDecoder().decode(SmartRules.self,from:Data("{\"conditions\":[{\"field\":\"notImplemented\"}]}".utf8)))
    }
    func testLiveMembersOrdinarySourceCopiesPersistenceAndAny() throws {
        let (folder,catalog,root) = try fixture(12); defer { try? FileManager.default.removeItem(at:folder) }
        try catalog.collection(name:"Manual",id:"m"); try catalog.membership(ids:["00000","00001","00002"],collection:"m",add:true)
        let rules = SmartRules(all:false,source:"collection:m",conditions:[SmartRule(field:.rating,op:.atLeast,value:"4"),SmartRule(field:.virtualCopy,op:.equal,value:"true")])
        let collection = try save(rules,catalog:catalog)
        XCTAssertTrue(try catalog.members("s").isEmpty)
        try catalog.setOrganization(ids:["00000"],rating:5)
        XCTAssertEqual(try catalog.members("s"),["00000"])
        let copy = try XCTUnwrap(catalog.createVirtualCopies(ids:["00001"]).first)
        XCTAssertEqual(try catalog.members("s"),["00000",copy.id])
        try catalog.membership(ids:[copy.id],collection:"m",add:false)
        XCTAssertEqual(try catalog.members("s"),["00000"])
        XCTAssertThrowsError(try catalog.membership(ids:["00001"],collection:"s",add:true))
        XCTAssertThrowsError(try catalog.restoreMembership(["00000":false],collection:"s"))
        XCTAssertThrowsError(try catalog.collectResults(PhotoQuery(),collection:"s"))
        XCTAssertThrowsError(try catalog.collection(name:"Overwrite",id:"s"))
        let rows = try catalog.database.read { try Int.fetchOne($0,sql:"SELECT count(*) FROM membership WHERE collectionID='s'") }
        XCTAssertEqual(rows,0)
        let backup = folder.appendingPathComponent("backup.sqlite"); try catalog.backup(to:backup)
        let reopened = try CatalogStore.restore(from:backup,to:folder.appendingPathComponent("restored"))
        XCTAssertEqual(try reopened.collections().first(where:{$0.id == "s"}),collection)
        XCTAssertEqual(try reopened.members("s"),["00000"])
        _ = try catalog.setVersionDeletion(["00000":true]); XCTAssertTrue(try catalog.members("s").isEmpty)
        // Folder source uses the existing recursive SQL boundary.
        _ = try save(SmartRules(source:"folder:"+root.id+":folder",conditions:[SmartRule(field:.copyName,op:.contains,value:"副本")]),id:"copies",catalog:catalog)
        XCTAssertEqual(try catalog.members("copies"),[copy.id])
    }
    @MainActor func testHoldFullMembershipOrderSelectionUndoAndRuleChanges() throws {
        let (folder,catalog,_) = try fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try catalog.collection(name:"Manual",id:"m")
        try catalog.membership(ids:try catalog.photos().map(\.id),collection:"m",add:true)
        let rules = SmartRules(source:"collection:m",conditions:[SmartRule(field:.rating,op:.atLeast,value:"0")])
        let model = AppModel(); model.catalog = catalog; try model.reload()
        model.undo.groupsByEvent = false; model.undo.beginUndoGrouping()
        XCTAssertTrue(model.saveSmartCollection(id:"s",name:"All",rules:rules))
        if model.undo.groupingLevel > 0 { model.undo.endUndoGrouping() }
        model.holdFilterResults = true; model.filterChanged()
        let before = try catalog.exportPhotos(ids:catalog.members("s"),query:model.query).map(\.id)
        XCTAssertEqual(before.count,405)
        try catalog.setOrganization(ids:["00000"],rating:5)
        let copy = try XCTUnwrap(catalog.createVirtualCopies(ids:["00001"]).first)
        try model.reload(); XCTAssertEqual(model.resultCount,405)
        XCTAssertFalse(try catalog.resultIDs(model.query,within:[copy.id]).contains(copy.id))
        model.selection = ["00000"]; model.undo.beginUndoGrouping(); model.membership("m",add:false)
        if model.undo.groupingLevel > 0 { model.undo.endUndoGrouping() }
        XCTAssertEqual(model.resultCount,404); XCTAssertNotEqual(model.activeID,"00000")
        model.undo.undo(); XCTAssertEqual(model.resultCount,405)
        _ = try catalog.setVersionDeletion(["00002":true]); try model.reload(); XCTAssertEqual(model.resultCount,404)
        var revised = rules; revised.conditions = [SmartRule(field:.rating,op:.equal,value:"5")]
        model.undo.beginUndoGrouping()
        XCTAssertTrue(model.saveSmartCollection(id:"s",name:"Five",rules:revised))
        if model.undo.groupingLevel > 0 { model.undo.endUndoGrouping() }
        XCTAssertEqual(model.resultCount,try catalog.members("s").count)
        try catalog.setOrganization(ids:["00000"],rating:0); try model.reload()
        XCTAssertTrue(try catalog.resultIDs(model.query,within:["00000"]).contains("00000"),"No longer matching stays held")
        model.refreshResults(); XCTAssertFalse(try catalog.resultIDs(model.query,within:["00000"]).contains("00000"))
        model.undo.beginUndoGrouping(); model.deleteSmartCollection("s"); XCTAssertFalse(model.collections.contains { $0.id == "s" })
        if model.undo.groupingLevel > 0 { model.undo.endUndoGrouping() }
        model.undo.undo(); XCTAssertTrue(model.collections.contains { $0.id == "s" }); model.undo.redo()
        XCTAssertFalse(model.collections.contains { $0.id == "s" })
        let filtered = PhotoQuery(scope:"collection:m",search:"IMG_",ratingThreshold:4,flags:[1],keyword:"travel",metadata:LibraryMetadataFilter(camera:"Cam",minimumISO:"100",dateFrom:"2024-01-01"))
        let saved = try SmartRules.from(filtered)
        XCTAssertEqual(saved.source,"collection:m"); XCTAssertEqual(saved.conditions.count,7)
        let flat = try SmartRules.from(PhotoQuery(ratingThreshold:4,smart:rules))
        XCTAssertEqual(flat.source,"collection:m"); XCTAssertEqual(flat.conditions.count,2)
        var any = rules; any.all = false
        XCTAssertEqual(try SmartRules.from(PhotoQuery(smart:any)),any)
        XCTAssertThrowsError(try SmartRules.from(PhotoQuery(ratingThreshold:4,smart:any)))
    }
    func testSQLQueryPerformanceWithoutLoadingRecipes() throws {
        let (folder,catalog,_) = try fixture(5000); defer { try? FileManager.default.removeItem(at:folder) }
        let rules = SmartRules(conditions:[SmartRule(field:.rating,op:.atLeast,value:"3"),SmartRule(field:.iso,op:.between,value:"100",upper:"1600"),SmartRule(field:.camera,op:.contains,value:"Cam")])
        let collection = try save(rules,catalog:catalog), query = PhotoQuery(smart:rules)
        let start = Date()
        for _ in 0..<5 { XCTAssertGreaterThan(try catalog.collectionCount(collection),0); XCTAssertEqual(try catalog.page(query,offset:200).photos.count,200) }
        print("SMART_SQL_5000_FIVE_COUNT_AND_PAGE_SECONDS=\(Date().timeIntervalSince(start))")
    }
}
