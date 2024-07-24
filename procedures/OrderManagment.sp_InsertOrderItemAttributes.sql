--liquibase formatted sql

--changeset DigitalSales:D376B0F5-D980-4C42-8BE8-60102628E3F5 stripComments:false runOnChange:true splitStatements:false
CREATE OR ALTER PROCEDURE OrderManagment.sp_InsertOrderItemAttributes
    @Attributes Orders.OrderItemMetadataType READONLY
AS
BEGIN
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED

    INSERT INTO OrderManagment.tblOrderItemAttributeType ([Name])
    SELECT DISTINCT a.[Type]
    FROM @Attributes a
    WHERE NOT EXISTS (SELECT 1 FROM OrderManagment.tblOrderItemAttributeType WHERE [Name] = a.[Type])

    INSERT INTO OrderManagment.tblOrderItemAttribute (OrderItemId, TypeId, [Value])
    SELECT
        a.OrderItemId,
        t.TypeId,
        a.[Value]
    FROM @Attributes a
		JOIN OrderManagment.tblOrderItemAttributeType t ON a.[Type] = t.[Name]
	WHERE NOT EXISTS(SELECT 1 FROM OrderManagment.tblOrderItemAttribute WHERE OrderItemId = a.OrderItemId AND TypeId = t.TypeId)
END
