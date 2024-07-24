--liquibase formatted sql

--changeset DigitalSales:E06C4CC3-F034-4D55-9FA1-7737FC303348 stripComments:false runOnChange:true splitStatements:false
CREATE OR ALTER PROCEDURE OrderManagment.sp_InsertOrderItemReferenceNumbers
    @ReferenceNumbers Orders.OrderItemMetadataType READONLY
AS
BEGIN
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED

    INSERT INTO OrderManagment.tblOrderItemReferenceNumberType ([Name])
    SELECT DISTINCT r.[Type]
    FROM @ReferenceNumbers r
    WHERE NOT EXISTS (SELECT 1 FROM OrderManagment.tblOrderItemReferenceNumberType WHERE [Name] = r.[Type])

    INSERT INTO OrderManagment.tblOrderItemReferenceNumberSource ([Name])
    SELECT DISTINCT r.[SubType]
    FROM @ReferenceNumbers r
    WHERE NOT EXISTS (SELECT 1 FROM OrderManagment.tblOrderItemReferenceNumberSource WHERE [Name] = r.[SubType])

    INSERT INTO OrderManagment.tblOrderItemReferenceNumber (OrderItemId, SourceId, TypeId, [Value])
    SELECT
        r.OrderItemId,
        s.SourceId,
        t.TypeId,
        r.[Value]
    FROM @ReferenceNumbers r
   		JOIN OrderManagment.tblOrderItemReferenceNumberType t ON r.[Type] = t.[Name]
		JOIN OrderManagment.tblOrderItemReferenceNumberSource s ON r.[SubType] = s.[Name]
	WHERE NOT EXISTS(SELECT 1 FROM OrderManagment.tblOrderItemReferenceNumber WHERE OrderItemId = r.OrderItemId AND SourceId = s.SourceId AND TypeId = t.TypeId)
END
