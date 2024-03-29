--liquibase formatted sql

--changeset KarinaMasihHudson:0d102f22f9534e65aaad2330914959c7 stripComments:false runOnChange:true splitStatements:false

/*=============================================
              :
       Author : Karina Masih-Hudson
              :
  Create Date : 2024-02-12
              :
  Description : Handset orders and handset RMAs with rebate by carrier
              :
 SSIS Package : Executed by upload.P_HandsetRebateGenmobile
			  :
          Job :
              :
        Usage : EXEC [Report].[P_Report_HandsetRebateByCarrier] '2024-02-15','2024-02-17',270
              :
 =============================================*/

CREATE OR ALTER PROCEDURE [Report].[P_Report_HandsetRebateByCarrier]
    (
        @StartDate DATETIME, @EndDate DATETIME, @CarrierID INT
    )
AS

BEGIN TRY
    BEGIN
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

        --   testing
        --   DECLARE @StartDate DATETIME = DATEADD(wk, DATEDIFF(wk,0,GETDATE()),-7)--'2024-02-15'
        --         , @EndDate DATETIME = DATEADD(wk, DATEDIFF(wk,0,GETDATE()),-0)--'2024-02-17';
        --, @CarrierID int = 270;

        IF @StartDate IS NULL
            SET @StartDate = DATEADD(DAY, -1, CAST(GETDATE() AS DATE));

        IF @EndDate IS NULL
            SET @EndDate = CAST(GETDATE() AS DATE);


        DROP TABLE IF EXISTS #Orders;
        SELECT
            d.ID
            , n.Order_No
            , n.DateFilled
            , d.Product_ID
            , d.Price
            , n.OrderType_ID
            , a.ParentAccount_Account_ID AS [MA_Account_ID]
            , ma.Account_Name AS [MA_Account_Name]
            , n.Account_ID
            , a.Account_Name
            , d.SKU
            , REPLACE(d.Name, ',', ' ') AS [Name]
            , CAST(n.AuthNumber AS INT) AS AuthNumberInt
        INTO #Orders
        FROM dbo.Orders AS d
        JOIN dbo.Order_No AS n
            ON d.Order_No = n.Order_No
        JOIN [Products].[tblProductCarrierMapping] AS pcm
            ON
                pcm.ProductId = d.Product_ID
                AND pcm.CarrierId = @CarrierID
        JOIN dbo.Account AS a
            ON
                a.Account_ID = n.Account_ID
                AND ISNULL(a.IstestAccount, 0) = 0
        JOIN dbo.Account AS ma
            ON ma.Account_ID = a.ParentAccount_Account_ID
        WHERE
            n.DateFilled >= @StartDate
            AND n.DateFilled < @EndDate
            AND n.OrderType_ID IN (48, 49, 57, 58, 61, 62)
            AND n.Filled = 1
            AND n.Process = 1
            AND n.Void = 0;

        DROP TABLE IF EXISTS #RMAOriginalOrder
        SELECT
            o.ID
            , o.Order_No
            , o.DateFilled
            , o.Name
            , o.Product_ID
            , o.Price
            , o.OrderType_ID
            , o.MA_Account_ID
            , o.MA_Account_Name
            , o.Account_ID
            , o.Account_Name
            , o.SKU
            , o.AuthNumberInt
            , o2.ID AS [OriginalOrderID]
        INTO #RMAOriginalOrder
        FROM #Orders AS o
        JOIN dbo.Orders AS o2
            ON
                o2.Order_No = o.AuthNumberInt
                AND o2.SKU = o.SKU
        WHERE o.OrderType_ID IN (61, 62)


        DROP TABLE IF EXISTS #OrdersItemAddons

        SELECT
            oia.OrderID
            , oia.AddonsValue
            , aof.AddonTypeName AS [AOTName]
        INTO #OrdersItemAddons
        FROM #Orders AS o
        JOIN dbo.tblOrderItemAddons AS oia
            ON o.ID = oia.OrderID
        JOIN dbo.tblAddonFamily AS aof
            ON
                aof.AddonID = oia.AddonsID
                AND aof.AddonTypeName IN (
                    'DeviceType', 'DeviceBYOPType',
                    'SIMType', 'SIMBYOPType',
                    'PhoneNumberType', 'ReturnPhoneType'
                );

        DROP TABLE IF EXISTS #RMAItemAddons

        SELECT
            r.ID AS [OrderID]
            , oia.AddonsValue
            , aof.AddonTypeName AS [AOTName]
        INTO #RMAItemAddons
        FROM #RMAOriginalOrder AS r
        JOIN dbo.tblOrderItemAddons AS oia
            ON r.OriginalOrderID = oia.OrderID
        JOIN dbo.tblAddonFamily AS aof
            ON
                aof.AddonID = oia.AddonsID
                AND aof.AddonTypeName IN (
                    'DeviceType', 'DeviceBYOPType',
                    'SIMType', 'SIMBYOPType',
                    'PhoneNumberType', 'ReturnPhoneType'
                );


        DROP TABLE IF EXISTS #IMEI

        SELECT
            o.OrderID
            , o.AddonsValue AS [IMEI]
        INTO #IMEI
        FROM #OrdersItemAddons AS o
        WHERE o.AOTName IN ('DeviceType', 'DeviceBYOPType');

        INSERT INTO #IMEI
        SELECT
            r.OrderID
            , r.AddonsValue
        FROM #RMAItemAddons AS r
        WHERE r.AOTName IN ('DeviceType', 'DeviceBYOPType');


        DROP TABLE IF EXISTS #SIM
        SELECT
            o.OrderID
            , o.AddonsValue AS [SIM]
        INTO #SIM
        FROM #OrdersItemAddons AS o
        WHERE o.AOTName IN ('SIMType', 'SIMBYOPType');

        INSERT INTO #SIM
        SELECT
            r.OrderID
            , r.AddonsValue AS [SIM]
        FROM #RMAItemAddons AS r
        WHERE r.AOTName IN ('SIMType', 'SIMBYOPType');

        DROP TABLE IF EXISTS #PhoneNumbers

        SELECT DISTINCT
            o.OrderID
            , o.AddonsValue AS [PhoneNumber]
        INTO #PhoneNumbers
        FROM #OrdersItemAddons AS o
        WHERE o.AOTName IN ('PhoneNumberType', 'ReturnPhoneType');

        INSERT INTO #PhoneNumbers
        SELECT DISTINCT
            r.OrderID
            , r.AddonsValue AS [PhoneNumber]
        FROM #RMAItemAddons AS r
        WHERE r.AOTName IN ('PhoneNumberType', 'ReturnPhoneType');


        DROP TABLE IF EXISTS #ActivationOrder;

        SELECT i.OrderID, o.id AS [ActivationID], od.Order_No AS [ActivationOrderNo]
        INTO #ActivationOrder
        FROM #IMEI AS i
        JOIN dbo.tblOrderItemAddons AS oia
            ON oia.AddonsValue = i.IMEI
        JOIN dbo.Orders AS o
            ON o.ID = oia.OrderID
        JOIN dbo.Order_No AS od
            ON od.Order_No = o.Order_No
        WHERE
            od.OrderType_ID IN (22, 23)
            AND od.Process = 1
            AND od.Filled = 1
            AND od.Void = 0
            AND ISNULL(o.ParentItemID, 0) IN (0, 1)


        DROP TABLE IF EXISTS #Promotion;

        SELECT ao.OrderID, od.OrderTotal AS [Rebate]
        INTO #Promotion
        FROM #ActivationOrder AS ao
        JOIN dbo.Order_No AS od
            ON
                od.AuthNumber = CAST(ao.ActivationOrderNo AS NVARCHAR(50))
                AND od.OrderType_ID IN (59, 60)
        WHERE
            od.Process = 1
            AND od.Filled = 1
            AND od.Void = 0



        SELECT DISTINCT
            o.Order_No AS [ReferenceNumber]
            , o.DateFilled
            , o.Name
            , o.Price
            , ph.PhoneNumber
            , s.SIM
            , ot.OrderType_Desc AS [OrderType]
            , o.MA_Account_ID AS [MasterAgentID]
            , o.MA_Account_Name AS [MasterAgentName]
            , o.Account_ID AS [StoreID]
            , o.Account_Name AS [StoreName]
            , i.IMEI AS [ESN]
            , pr.Rebate
        FROM #Orders AS o
        JOIN dbo.OrderType_ID AS ot
            ON ot.OrderType_ID = o.OrderType_ID
        LEFT JOIN #IMEI AS i
            ON i.OrderID = o.ID
        LEFT JOIN #SIM AS s
            ON s.OrderID = o.ID
        LEFT JOIN #PhoneNumbers AS ph
            ON ph.OrderID = o.ID
        LEFT JOIN #Promotion AS pr
            ON pr.OrderID = o.ID
        WHERE o.OrderType_ID IN (48, 49, 57, 58)
        UNION
        SELECT DISTINCT
            o.Order_No
            , o.DateFilled
            , o.Name
            , o.Price
            , ph.PhoneNumber
            , s.SIM
            , ot.OrderType_Desc
            , o.MA_Account_ID
            , o.MA_Account_Name
            , o.Account_ID
            , o.Account_Name
            , i.IMEI
            , pr.Rebate
        FROM #RMAOriginalOrder AS o
        JOIN dbo.OrderType_ID AS ot
            ON ot.OrderType_ID = o.OrderType_ID
        LEFT JOIN #IMEI AS i
            ON i.OrderID = o.OriginalOrderID
        LEFT JOIN #SIM AS s
            ON s.OrderID = o.OriginalOrderID
        LEFT JOIN #PhoneNumbers AS ph
            ON ph.OrderID = o.OriginalOrderID
        LEFT JOIN #Promotion AS pr
            ON pr.OrderID = o.ID

    END;
END TRY
BEGIN CATCH
    SELECT
        ERROR_NUMBER() AS ErrorNumber
        , ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
