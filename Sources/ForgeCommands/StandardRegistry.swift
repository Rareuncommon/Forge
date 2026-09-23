import ForgeCore

extension CommandRegistry {
    /// The built-in command catalog. Every entry here must appear in FEATURES.md or be
    /// infrastructure (document/edit/help).
    public static let standard: CommandRegistry = {
        var r = CommandRegistry()
        // session
        r.register(DocumentNew.self)
        r.register(DocumentList.self)
        r.register(DocumentActivate.self)
        r.register(DocumentClose.self)
        r.register(DocumentState.self)
        r.register(EditUndo.self)
        r.register(EditRedo.self)
        r.register(TransactionBegin.self)
        r.register(TransactionCommit.self)
        r.register(TransactionRollback.self)
        // discovery
        r.register(HelpListCommands.self)
        r.register(HelpDescribeCommand.self)
        r.register(HelpSearchCommands.self)
        // bodies
        r.register(BodyCreateBox.self)
        r.register(BodyCreateCylinder.self)
        r.register(BodyCreateSphere.self)
        r.register(BodyCreateCone.self)
        r.register(BodyCreateTorus.self)
        r.register(BodyBoolean.self)
        r.register(BodyTransform.self)
        r.register(BodyFilletEdges.self)
        r.register(BodyDelete.self)
        r.register(BodyRename.self)
        // queries
        r.register(QueryBodies.self)
        r.register(QueryFaces.self)
        r.register(QueryEdges.self)
        r.register(QueryEntity.self)
        r.register(QueryMassProperties.self)
        r.register(QueryMeasure.self)
        r.register(QueryValidate.self)
        r.register(QueryCompareToSpec.self)
        // selection
        r.register(SelectionSet.self)
        r.register(SelectionGet.self)
        r.register(SelectionClear.self)
        // view
        r.register(ViewRender.self)
        r.register(ViewRenderMultiview.self)
        r.register(ViewPick.self)
        // export
        r.register(ExportSTEP.self)
        r.register(ExportSTL.self)
        return r
    }()
}
