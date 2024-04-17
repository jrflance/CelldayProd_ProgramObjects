--liquibase formatted sql

--changeset Nicolas Griesdorn a3c74c3f stripComments:false runOnChange:true splitStatements:false
/* =============================================
				:
	Author		: Nic Griesdorn
				:
	Created		: 2024-04-15
				:
	Description	: SP used in CRM to make new Products reassignable
				:
============================================= */
CREATE OR ALTER PROCEDURE [Report].[P_Report_Product_IsReassignable]
    (
        @SessionID INT
        , @Option INT
        , @ProductID INT
    )
AS
BEGIN TRY

    IF ISNULL(@SessionID, 0) <> 2
        RAISERROR ('This report is highly restricted. Please see your T-Cetra representative if you wish to request access.', 12, 1);

    IF ISNULL(@ProductID, 0) = 0
        RAISERROR ('Product ID cannot be left blank, please provide a valid Product ID and try again.', 12, 1);



    IF @Option = 0 --View
        BEGIN
            SELECT
                rp.Product_ID,
                p.Name AS [Product Name],
                rp.IsReassignable,
                rp.Admin_Name,
                rp.Admin_Updated
            FROM Account.tblIsReassignableProductIDs AS rp
            JOIN Products AS p ON p.Product_ID = rp.Product_ID
            WHERE rp.Product_ID = @ProductID

        END;

    IF @Option = 1 --Insert Products
        BEGIN

            IF EXISTS (SELECT * FROM Account.tblIsReassignableProductIDs WHERE Product_ID = @ProductID)
                RAISERROR ('This Product ID already exists in this table, please check the Product ID and try again.', 13, 1);

            INSERT INTO Account.tblIsReassignableProductIDs
            (
                Product_ID,
                IsReassignable,
                Admin_Name,
                Admin_Updated
            )
            VALUES
            (
                @ProductID,    -- Product_ID - int
                1, -- IsReassignable - smallint
                'ProductIsReassignableCRM',    -- Admin_Name - varchar(50)
                GETDATE()     -- Admin_Updated - datetime
            )

            SELECT
                rp.Product_ID,
                p.Name AS [Product Name],
                rp.IsReassignable,
                rp.Admin_Name,
                rp.Admin_Updated
            FROM Account.tblIsReassignableProductIDs AS rp
            JOIN Products AS p ON p.Product_ID = rp.Product_ID
            WHERE rp.Product_ID = @ProductID
        END;

    IF @Option = 2 --Update PAK table from newly Inserted Products
        BEGIN
            IF NOT EXISTS (SELECT * FROM Account.tblIsReassignableProductIDs WHERE Product_ID = @ProductID)
                RAISERROR (
                    'The Product ID provided is not marked as IsReassignable, please mark the Product as reassignable then attempt the update again.',
                    14,
                    1
                );

            IF EXISTS (SELECT * FROM Account.tblIsReassignableProductIDs WHERE Product_ID = @ProductID)
                BEGIN
                    UPDATE dbo.Phone_Active_Kit
                    SET
                        IsReassignable = 1
                        , User_Updated = 'IsReassignableCRM'
                        , Date_Updated = GETDATE()
                    WHERE Product_ID = @ProductID AND IsReassignable = 0 AND Status = 1
                END;

            SELECT * FROM dbo.Phone_Active_Kit
            WHERE Product_ID = @ProductID AND IsReassignable = 1 AND Status = 1
        END;

END TRY
BEGIN CATCH
    SELECT ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
