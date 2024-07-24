--liquibase formatted sql

--changeset DigitalSales:C83DBDFF-06F4-4592-9D07-78E202E54ECA stripComments:false runOnChange:true splitStatements:false
CREATE OR ALTER PROCEDURE Orders.sp_InsertOrUpdateOrderPricingDetails
    @PricingDetails Orders.OrderItemMetadataType READONLY
AS
BEGIN
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED

    INSERT INTO Orders.tblOrderPricingType ([Name])
    SELECT DISTINCT pd.[Type]
    FROM @PricingDetails pd
    WHERE NOT EXISTS (SELECT 1 FROM Orders.tblOrderPricingType WHERE [Name] = pd.[Type])

    INSERT INTO Orders.tblOrderPricingSubType ([TypeId], [CarrierId], [CarrierReference], [Name])
    SELECT DISTINCT opt.OrderPricingTypeId, pcm.CarrierId, pd.[SubType], 'Unknown'
    FROM @PricingDetails pd
        JOIN Orders.tblOrderPricingType opt ON pd.[Type] = opt.[Name]
        JOIN dbo.Orders o ON o.ID = pd.OrderItemId
        JOIN Products.tblProductCarrierMapping pcm ON pcm.ProductId = o.Product_ID
    WHERE pd.[SubType] IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM Orders.tblOrderPricingSubType
        WHERE [TypeId] = opt.OrderPricingTypeId
            AND [CarrierReference] = pd.[SubType]
    )

    UPDATE opd
    SET
        opd.[Value] = pd.[Value],
        opd.[Date] = GETDATE()
    FROM Orders.tblOrderPricingDetails opd
    JOIN @PricingDetails pd ON opd.OrderItemId = pd.OrderItemId
    JOIN Orders.tblOrderPricingType opt ON pd.[Type] = opt.[Name]
    LEFT JOIN Orders.tblOrderPricingSubType opst ON pd.[SubType] = opst.[CarrierReference]
    WHERE opd.OrderPricingTypeId = opt.OrderPricingTypeId
      AND (opd.SubTypeId = opst.SubTypeId OR (opd.SubTypeId IS NULL AND opst.SubTypeId IS NULL))

    INSERT INTO Orders.tblOrderPricingDetails (OrderItemId, OrderPricingTypeId, SubTypeId, [Value], [Date])
    SELECT
        pd.OrderItemId,
        opt.OrderPricingTypeId,
        opst.SubTypeId,
        pd.[Value],
        GETDATE()
    FROM @PricingDetails pd
        JOIN Orders.tblOrderPricingType opt ON pd.[Type] = opt.[Name]
        LEFT JOIN Orders.tblOrderPricingSubType opst ON pd.[SubType] = opst.[CarrierReference]
    WHERE NOT EXISTS (
        SELECT 1
        FROM Orders.tblOrderPricingDetails opd
        WHERE opd.OrderItemId = pd.OrderItemId
          AND opd.OrderPricingTypeId = opt.OrderPricingTypeId
          AND (opd.SubTypeId = opst.SubTypeId OR (opd.SubTypeId IS NULL AND opst.SubTypeId IS NULL))
    )
END
